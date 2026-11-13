-- Practice management, part 6: due-diligence intake and the conflicts check.
--
-- Accountants and tax consultants are designated non-financial businesses (MLPPA 2022): before it takes on a client a
-- firm records who the client is and checks the new work against its other work, and it keeps those records for at least
-- five years after the engagement ends. These are the practice's own records, kept apart from the business's CAC record
-- (kyc_profiles stays the owner's: nothing in it is copied here).
--   practice_intakes            one per prospective client: registration details, a risk rating (high whenever a director
--                               or owner is a politically exposed person), the conflicts check's state and outcome, and a
--                               partner's declaration of the client's written authority (full mandate). Status draft;
--                               engaged once the client link is active; declined when a partner refuses it.
--   practice_intake_people      directors, beneficial owners and related people. An ID number only as its last 4
--                               characters: a longer run of digits (spaces and dashes aside) anywhere in a person's
--                               details is refused.
--   practice_intake_docs        supporting documents in the documents bucket under practice/<pid>/intake/<iid>/.
--   practice_opposing_parties   the other side of the firm's matters for its clients.
--   practice_conflict_hits      what the last conflicts check found.
-- The conflicts check (private.conflict_scan) looks only inside the practice: its current and former clients, its other
-- intakes and their people, its opposing parties and, when the firm asks for it (practices.conflict_scan_books), its
-- active clients' customers and suppliers. Names are compared without accents, case, punctuation or words such as
-- "Limited"; RC numbers and Tax IDs without spaces, punctuation or an RC/BN/IT prefix; people as the NIN check compares
-- them. A partner clears or refuses what it finds, with a note.
-- An intake is cleared (private.intake_cleared) when it has a risk rating and its last check, run after the last change
-- to its name, numbers or people (edited_at), found nothing or was cleared. Inviting a business owner needs a cleared
-- involved intake, and the owner's acceptance needs it still cleared: while the invitation waits the intake's substance
-- does not change, and refusing it withdraws the invitation. A link the business starts (and every active link made before
-- intakes existed) gets a draft intake marked "due diligence incomplete" until the firm clears it. Once an engagement's
-- intake is cleared, or once it has a retention date, it is kept as it is. Intakes, their people and documents cannot be
-- deleted before their retention date; a business deleted for good leaves the practice's intake in place, no longer linked
-- to it. Practice files live under practice/<pid>/ in the documents bucket: intake files for the practice's partners and
-- managers, letter files for its people, exports for its partners; nobody deletes them.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
alter table public.practices add column if not exists conflict_scan_books boolean not null default false;

create table public.practice_intakes (
  id uuid primary key default gen_random_uuid(),
  practice_id uuid not null references public.practices(id) on delete cascade,
  status text not null default 'draft' check (status in ('draft', 'engaged', 'declined')),
  mode_requested text not null default 'involved' check (mode_requested in ('involved', 'full')),
  legal_name text not null check (length(trim(legal_name)) between 2 and 160),
  entity_type text check (entity_type in ('company', 'business_name', 'incorporated_trustees', 'partnership', 'individual')),
  rc_number text check (length(rc_number) <= 40),
  tax_id text check (length(tax_id) <= 40),
  address text check (length(address) <= 300),
  industry text check (length(industry) <= 80),
  risk_rating text check (risk_rating in ('low', 'medium', 'high')),
  risk_reason text check (length(risk_reason) <= 1000),
  pep_present boolean not null default false,
  dd_incomplete boolean not null default false,
  conflict_status text not null default 'pending' check (conflict_status in ('pending', 'none', 'hits', 'cleared', 'refused')),
  conflict_note text check (length(conflict_note) <= 1000),
  conflict_decided_by uuid references public.practice_members(id) on delete set null,
  conflict_decided_at timestamptz,
  checked_at timestamptz,
  -- Moved only by a change to the name, RC number, Tax ID or people: a check run before it no longer counts.
  edited_at timestamptz not null default now(),
  authority_declared_by uuid references public.practice_members(id) on delete set null,
  authority_declared_at timestamptz,
  authority_statement text,
  authority_doc_path text check (authority_doc_path like 'practice/' || practice_id::text || '/intake/' || id::text || '/_%'),
  client_id uuid references public.practice_clients(id) on delete set null,
  org_id uuid references public.orgs(id) on delete set null,
  retain_until date,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index practice_intakes_practice on public.practice_intakes(practice_id, status, created_at desc);
create index practice_intakes_client on public.practice_intakes(client_id) where client_id is not null;
create index practice_intakes_org on public.practice_intakes(org_id) where org_id is not null;
create index practice_intakes_decided_by on public.practice_intakes(conflict_decided_by) where conflict_decided_by is not null;
create index practice_intakes_declared_by on public.practice_intakes(authority_declared_by) where authority_declared_by is not null;
create index practice_intakes_created_by on public.practice_intakes(created_by);
alter table public.practice_intakes enable row level security;
revoke all on public.practice_intakes from anon, authenticated;

-- A run of five or more digits (spaces and dashes aside) in a name, role or nationality is an ID number pasted in the
-- wrong place.
create table public.practice_intake_people (
  id uuid primary key default gen_random_uuid(),
  intake_id uuid not null references public.practice_intakes(id) on delete cascade,
  practice_id uuid not null references public.practices(id) on delete cascade,
  kind text not null check (kind in ('director', 'beneficial_owner', 'related')),
  name text not null check (length(trim(name)) between 2 and 120 and regexp_replace(name, '[[:space:]-]', '', 'g') !~ '[0-9]{5,}'),
  role text check (length(role) <= 80 and regexp_replace(role, '[[:space:]-]', '', 'g') !~ '[0-9]{5,}'),
  ownership_pct numeric(5,2) check (ownership_pct between 0 and 100),
  nationality text check (length(nationality) <= 60 and regexp_replace(nationality, '[[:space:]-]', '', 'g') !~ '[0-9]{5,}'),
  is_pep boolean not null default false,
  id_type text check (id_type in ('nin', 'bvn', 'passport', 'drivers_licence', 'voters_card', 'cac', 'other')),
  id_last4 text check (id_last4 ~ '^[A-Za-z0-9]{4}$'),
  created_at timestamptz not null default now()
);
create index practice_intake_people_intake on public.practice_intake_people(intake_id);
create index practice_intake_people_practice on public.practice_intake_people(practice_id);
alter table public.practice_intake_people enable row level security;
revoke all on public.practice_intake_people from anon, authenticated;

create table public.practice_intake_docs (
  id uuid primary key default gen_random_uuid(),
  intake_id uuid not null references public.practice_intakes(id) on delete cascade,
  practice_id uuid not null references public.practices(id) on delete cascade,
  kind text not null default 'other' check (kind in ('cac', 'id', 'address', 'other')),
  name text not null check (length(trim(name)) between 1 and 200),
  path text not null check (path like 'practice/' || practice_id::text || '/intake/' || intake_id::text || '/_%' and length(path) <= 500),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  added_by uuid references public.practice_members(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (intake_id, path)
);
create index practice_intake_docs_practice on public.practice_intake_docs(practice_id);
create index practice_intake_docs_added_by on public.practice_intake_docs(added_by) where added_by is not null;
alter table public.practice_intake_docs enable row level security;
revoke all on public.practice_intake_docs from anon, authenticated;

create table public.practice_opposing_parties (
  id uuid primary key default gen_random_uuid(),
  practice_id uuid not null references public.practices(id) on delete cascade,
  client_id uuid references public.practice_clients(id) on delete set null,
  name text not null check (length(trim(name)) between 2 and 160),
  rc_number text check (length(rc_number) <= 40),
  note text check (length(note) <= 500),
  created_by uuid references public.practice_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index practice_opposing_parties_practice on public.practice_opposing_parties(practice_id);
create index practice_opposing_parties_client on public.practice_opposing_parties(client_id) where client_id is not null;
create index practice_opposing_parties_created_by on public.practice_opposing_parties(created_by) where created_by is not null;
alter table public.practice_opposing_parties enable row level security;
revoke all on public.practice_opposing_parties from anon, authenticated;

-- subject: what of the prospect matched (its name, RC number, Tax ID, or one of its people); match_name: what it matched.
create table public.practice_conflict_hits (
  id uuid primary key default gen_random_uuid(),
  intake_id uuid not null references public.practice_intakes(id) on delete cascade,
  practice_id uuid not null references public.practices(id) on delete cascade,
  kind text not null check (kind in ('client', 'prospect', 'related_party', 'opposing_party', 'books')),
  matched_on text not null check (matched_on in ('rc_number', 'tax_id', 'name', 'person')),
  subject text not null,
  match_name text,
  score numeric(4,2),
  source_client_id uuid references public.practice_clients(id) on delete set null,
  source_intake_id uuid references public.practice_intakes(id) on delete set null,
  source_opposing_id uuid references public.practice_opposing_parties(id) on delete set null,
  created_at timestamptz not null default now()
);
create index practice_conflict_hits_intake on public.practice_conflict_hits(intake_id);
create index practice_conflict_hits_practice on public.practice_conflict_hits(practice_id);
create index practice_conflict_hits_client on public.practice_conflict_hits(source_client_id) where source_client_id is not null;
create index practice_conflict_hits_source_intake on public.practice_conflict_hits(source_intake_id) where source_intake_id is not null;
create index practice_conflict_hits_opposing on public.practice_conflict_hits(source_opposing_id) where source_opposing_id is not null;
alter table public.practice_conflict_hits enable row level security;
revoke all on public.practice_conflict_hits from anon, authenticated;

-- The client link's intake.
alter table public.practice_clients add constraint practice_clients_intake_id_fkey
  foreign key (intake_id) references public.practice_intakes(id) on delete set null;
create index practice_clients_intake_id on public.practice_clients(intake_id) where intake_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
-- A name without accents: the combining marks (U+0300 to U+036F) of its decomposed form removed, so "Ọlá Àdé" is "Ola Ade";
-- and the Hausa hooked letters, which do not decompose, as plain ones: ɓ ɗ ƙ ƴ (U+0253, U+0257, U+0199, U+01B4) and their
-- capitals Ɓ Ɗ Ƙ Ƴ (U+0181, U+018A, U+0198, U+01B3) as b d k y and B D K Y, so "Ɗanjuma" is "Danjuma".
create or replace function private.fold_name(p text) returns text
language sql immutable set search_path = '' as $$
  select regexp_replace(translate(normalize(coalesce(p, ''), NFD), U&'\0253\0257\0199\01B4\0181\018A\0198\01B3', 'bdkyBDKY'),
    U&'[\0300-\036F]', '', 'g')
$$;

-- An RC number, BN number or Tax ID as compared: upper case, letters and digits only, without a leading RC, BN or IT.
-- "RC 123456" and "123456" are the same number. Null when nothing is left.
create or replace function private.norm_id(p text) returns text
language sql immutable set search_path = '' as $$
  select nullif(regexp_replace(regexp_replace(upper(coalesce(p, '')), '[^A-Z0-9]', '', 'g'), '^(RC|BN|IT)', ''), '')
$$;

-- Whether a text holds an ID number: five or more digits in a row once spaces and dashes are taken out, so
-- "1234 5678 901" and "1234-5678-901" count.
create or replace function private.has_id_number(p text) returns boolean
language sql immutable set search_path = '' as $$
  select regexp_replace(p, '[[:space:]-]', '', 'g') ~ '[0-9]{5,}'
$$;

-- How alike two company names are (0 to 1), either way round, without accents. 1 when every word that tells one of them
-- apart is in the other (name_match, which wants two such words or one of six letters or more); otherwise the share of the
-- prospect's distinguishing words found in the other name, or of the other's found in the prospect's when it has two such
-- words or more. 0.75 or more is a possible conflict: "Zenith Paints Distribution Ltd" and "Zenith Paints Ltd" are.
create or replace function private.company_name_score(p_prospect text, p_other text) returns numeric
language sql immutable set search_path = public, private as $$
  select case when private.name_match(a, b) or private.name_match(b, a) then 1.00
    else greatest(private.name_score(a, b), case when cardinality(private.name_words(b)) >= 2 then private.name_score(b, a) else 0 end) end
  from (select private.fold_name(p_prospect) as a, private.fold_name(p_other) as b) z
$$;

-- The text as an id, or null when it is not one.
create or replace function private.uuid_of(p text) returns uuid
language sql immutable set search_path = '' as $$
  select case when p ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then p::uuid end
$$;

-- How long records are kept: the given number of years from today, and never less than five. The one retention rule,
-- for intakes and for a business kept after its engagement ends.
create or replace function private.retain_date(p_years int) returns date
language sql stable set search_path = '' as $$
  select (current_date + make_interval(years => greatest(coalesce(p_years, 5), 5)))::date
$$;

-- Ready for an engagement: a risk rating, and a conflicts check that found nothing or was cleared, run after the last
-- change to the name, numbers or people.
create or replace function private.intake_cleared(i public.practice_intakes) returns boolean
language sql immutable set search_path = public, private as $$
  select coalesce(i.risk_rating is not null and i.conflict_status in ('none', 'cleared') and i.checked_at >= i.edited_at, false)
$$;

-- The intake, for its practice's partners and managers (locked when it is to be changed).
create or replace function private.intake_require(p_intake uuid, p_lock boolean default false) returns public.practice_intakes
language plpgsql set search_path = public, private as $$
declare i public.practice_intakes;
begin
  if p_lock then select * into i from practice_intakes where id = p_intake for update;
  else select * into i from practice_intakes where id = p_intake; end if;
  if i.id is null then raise exception 'Intake not found.'; end if;
  perform private.practice_require(i.practice_id, true);
  return i;
end $$;

-- "Due diligence incomplete": the client link is active and the intake is not cleared. Set again after every change.
create or replace function private.intake_settle(p_intake uuid) returns void
language sql set search_path = public, private as $$
  update practice_intakes x set dd_incomplete = (x.status = 'engaged' and not private.intake_cleared(x)), updated_at = now()
  where x.id = p_intake and x.dd_incomplete is distinct from (x.status = 'engaged' and not private.intake_cleared(x))
$$;

-- An intake kept as it is: the record of an engagement once its due diligence is done, or anything with a retention
-- date (the engagement ended, the invitation was withdrawn or declined). Changes then go on a new intake.
create or replace function private.intake_kept(i public.practice_intakes) returns boolean
language sql immutable set search_path = public, private as $$
  select i.retain_until is not null or (i.status = 'engaged' and private.intake_cleared(i))
$$;

-- Whether an invitation to the business owner, carrying this intake, is waiting for an answer.
create or replace function private.intake_invited(p_intake uuid) returns boolean
language sql stable set search_path = public, private as $$
  select exists (select 1 from practice_clients where intake_id = p_intake and status = 'invited')
$$;

-- An intake as the portal shows it: a list row, or in full with its people, documents and the last check's hits.
create or replace function private.intake_json(i public.practice_intakes, p_full boolean) returns jsonb
language sql stable set search_path = public, private as $$
  select case when not p_full then jsonb_build_object('id', i.id, 'status', i.status, 'mode_requested', i.mode_requested, 'legal_name', i.legal_name,
      'entity_type', i.entity_type, 'rc_number', i.rc_number, 'tax_id', i.tax_id, 'risk_rating', i.risk_rating, 'pep_present', i.pep_present,
      'dd_incomplete', i.dd_incomplete, 'conflict_status', i.conflict_status, 'checked_at', i.checked_at, 'cleared', private.intake_cleared(i),
      'authority_declared', i.authority_declared_at is not null, 'client_id', i.client_id, 'org_id', i.org_id, 'retain_until', i.retain_until,
      'created_at', i.created_at, 'updated_at', i.updated_at)
  else to_jsonb(i) || jsonb_build_object(
      'cleared', private.intake_cleared(i),
      'conflict_decided_by_name', (select display_name from practice_members where id = i.conflict_decided_by),
      'authority_declared_by_name', (select display_name from practice_members where id = i.authority_declared_by),
      'people', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'kind', p.kind, 'name', p.name, 'role', p.role,
          'ownership_pct', p.ownership_pct, 'nationality', p.nationality, 'is_pep', p.is_pep, 'id_type', p.id_type, 'id_last4', p.id_last4)
          order by case p.kind when 'director' then 1 when 'beneficial_owner' then 2 else 3 end, p.name, p.id), '[]'::jsonb)
        from practice_intake_people p where p.intake_id = i.id),
      'docs', (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'name', d.name, 'path', d.path, 'sha256', d.sha256,
          'added_by_name', pm.display_name, 'created_at', d.created_at) order by d.created_at, d.name), '[]'::jsonb)
        from practice_intake_docs d left join practice_members pm on pm.id = d.added_by where d.intake_id = i.id),
      'hits', (select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'kind', h.kind, 'matched_on', h.matched_on, 'subject', h.subject,
          'match_name', h.match_name, 'score', h.score, 'source_client_id', h.source_client_id, 'source_intake_id', h.source_intake_id,
          'source_opposing_id', h.source_opposing_id) order by h.kind, h.matched_on, h.score desc, h.match_name), '[]'::jsonb)
        from practice_conflict_hits h where h.intake_id = i.id)) end
$$;

-- ---------------------------------------------------------------------------
-- 3. The conflicts check
-- ---------------------------------------------------------------------------
-- Replaces the intake's hits with what it matches in its own practice, and says how many. Each party the practice has
-- worked for or with is compared by RC number and Tax ID (the same number), by name (company_name_score 0.75 or more),
-- and by the prospect's people (as the NIN check matches a person to a director); the people on the practice's other
-- intakes are compared with the prospect's people and with the prospect's own name (a person, or a business in a
-- person's name). One hit per party, match and subject, however many of the party's names match.
create or replace function private.conflict_scan(p_intake uuid) returns integer
language plpgsql set search_path = public, private as $$
declare i public.practice_intakes; v_books boolean; v_n integer;
begin
  select * into i from practice_intakes where id = p_intake;
  if not found then raise exception 'Intake not found.'; end if;
  select conflict_scan_books into v_books from practices where id = i.practice_id;
  delete from practice_conflict_hits where intake_id = i.id;
  with
  -- The prospect's people: first name, middle names and surname, without accents or titles.
  mine as (
    select p.name, z.t[1] as first, array_to_string(z.t[2:cardinality(z.t) - 1], ' ') as middle, z.t[cardinality(z.t)] as last
    from practice_intake_people p cross join lateral (select private.name_tokens(private.fold_name(p.name)) as t) z
    where p.intake_id = i.id and cardinality(z.t) > 0),
  -- The prospect's own name, read as a person's.
  me as (
    select z.t[1] as first, array_to_string(z.t[2:cardinality(z.t) - 1], ' ') as middle, z.t[cardinality(z.t)] as last
    from (select private.name_tokens(private.fold_name(i.legal_name)) as t) z
    where cardinality(z.t) > 0),
  -- The practice's parties: what they are, a name, an RC number and a Tax ID, and where they are recorded.
  parties as (
    -- Its clients whatever the state of the link: the business, the name on the link, and the client's intake (not the
    -- prospect's own link, nor an invitation that carries this intake).
    select 'client' as kind, v.name, v.rc, v.tax, pc.id as client_id, pc.intake_id, null::uuid as opposing_id
    from practice_clients pc
    left join orgs o on o.id = pc.org_id
    left join practice_intakes x on x.id = pc.intake_id and x.practice_id = i.practice_id
    cross join lateral (values (o.name, o.rc_number, o.tin), (pc.business_name, null, null), (x.legal_name, x.rc_number, x.tax_id)) v(name, rc, tax)
    where pc.practice_id = i.practice_id and pc.id is distinct from i.client_id and pc.intake_id is distinct from i.id and v.name is not null
    union all
    -- Its other intakes with no client link: prospects, and former clients whose business is gone.
    select case when x.status = 'engaged' then 'client' else 'prospect' end, x.legal_name, x.rc_number, x.tax_id, x.client_id, x.id, null
    from practice_intakes x
    where x.practice_id = i.practice_id and x.id <> i.id
      and not exists (select 1 from practice_clients pc where pc.intake_id = x.id and pc.practice_id = i.practice_id)
    union all
    select 'opposing_party', op.name, op.rc_number, null, op.client_id, null, op.id
    from practice_opposing_parties op where op.practice_id = i.practice_id
    union all
    -- Its active clients' customers and suppliers, when the firm asks for them.
    select 'books', cu.name, null, cu.tin, pc.id, null, null
    from practice_clients pc join customers cu on cu.org_id = pc.org_id
    where v_books and pc.practice_id = i.practice_id and pc.status = 'active' and pc.id is distinct from i.client_id
      and pc.intake_id is distinct from i.id and not cu.is_walk_in
    union all
    select 'books', ve.name, ve.rc_number, ve.tin, pc.id, null, null
    from practice_clients pc join vendors ve on ve.org_id = pc.org_id
    where v_books and pc.practice_id = i.practice_id and pc.status = 'active' and pc.id is distinct from i.client_id
      and pc.intake_id is distinct from i.id),
  matches as (
    select kind, 'rc_number' as matched_on, i.rc_number as subject, name as match_name, 1.00 as score, client_id, intake_id, opposing_id
    from parties where private.norm_id(rc) = private.norm_id(i.rc_number)
    union all
    select kind, 'tax_id', i.tax_id, name, 1.00, client_id, intake_id, opposing_id
    from parties where private.norm_id(tax) = private.norm_id(i.tax_id)
    union all
    select kind, 'name', i.legal_name, name, s.score, client_id, intake_id, opposing_id
    from parties cross join lateral (select private.company_name_score(i.legal_name, name) as score) s
    where s.score >= 0.75
    union all
    -- The prospect's people among the names of the clients, prospects and opposing parties.
    select p.kind, 'person', m.name, p.name, 1.00, p.client_id, p.intake_id, p.opposing_id
    from mine m join parties p on p.kind <> 'books'
    where private.identity_match(m.first, m.middle, m.last, jsonb_build_array(jsonb_build_object('name', private.fold_name(p.name)))) is not null
    union all
    -- ... and among the people recorded on the practice's other intakes.
    select 'related_party', 'person', m.name, rp.name, 1.00, x.client_id, x.id, null
    from mine m
    join practice_intake_people rp on rp.practice_id = i.practice_id and rp.intake_id <> i.id
    join practice_intakes x on x.id = rp.intake_id and x.practice_id = i.practice_id
    where private.identity_match(m.first, m.middle, m.last, jsonb_build_array(jsonb_build_object('name', private.fold_name(rp.name)))) is not null
    union all
    -- The prospect's own name among those people.
    select 'related_party', 'name', i.legal_name, rp.name, 1.00, x.client_id, x.id, null
    from me
    join practice_intake_people rp on rp.practice_id = i.practice_id and rp.intake_id <> i.id
    join practice_intakes x on x.id = rp.intake_id and x.practice_id = i.practice_id
    where private.identity_match(me.first, me.middle, me.last, jsonb_build_array(jsonb_build_object('name', private.fold_name(rp.name)))) is not null)
  insert into practice_conflict_hits (intake_id, practice_id, kind, matched_on, subject, match_name, score, source_client_id, source_intake_id, source_opposing_id)
  select distinct on (kind, matched_on, subject, client_id, intake_id, opposing_id)
    i.id, i.practice_id, kind, matched_on, subject, match_name, score, client_id, intake_id, opposing_id
  from matches
  order by kind, matched_on, subject, client_id, intake_id, opposing_id, score desc, match_name;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Keeping the records, and the client link
-- ---------------------------------------------------------------------------
-- Intakes, their people and their documents stay until their retention date (none yet: the engagement has not ended).
-- An intake's own deletion, once allowed, takes its people and documents with it. Saving an intake replaces its people
-- (counta.intake_save). A business deleted for good (app.allow_purge) leaves the practice's intake in place, no longer
-- linked to it, as the intake's org_id foreign key does, and kept at least five years from then.
create or replace function private.practice_intakes_retention() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_retain date;
begin
  if tg_table_name = 'practice_intakes' then
    v_retain := old.retain_until;
  else
    select retain_until into v_retain from practice_intakes where id = old.intake_id;
    if not found then return old; end if;
    if tg_table_name = 'practice_intake_people' and coalesce(current_setting('counta.intake_save', true), '') = 'on' then return old; end if;
  end if;
  if v_retain is not null and v_retain <= current_date then return old; end if;
  if tg_table_name = 'practice_intakes' and coalesce(current_setting('app.allow_purge', true), '') = 'on' then
    update practice_intakes set org_id = null, retain_until = coalesce(retain_until, private.retain_date(5)), updated_at = now() where id = old.id;
    return null;
  end if;
  raise exception 'Due-diligence records are kept until %.', coalesce(to_char(v_retain, 'DD Mon YYYY'), 'five years after the engagement ends');
end $$;

create trigger practice_intakes_retention before delete on public.practice_intakes
  for each row execute function private.practice_intakes_retention();
create trigger practice_intakes_retention before delete on public.practice_intake_people
  for each row execute function private.practice_intakes_retention();
create trigger practice_intakes_retention before delete on public.practice_intake_docs
  for each row execute function private.practice_intakes_retention();

-- The draft intake of an active client link that has none (the business started the link, or it came from a referral, a
-- directory request or before intakes existed): marked "due diligence incomplete", engaged, with the name on the link (else
-- the business's), its RC number and Tax ID, and nobody from its CAC record. The link then carries it. Returns its id.
create or replace function private.intake_for_client(p_client uuid) returns uuid
language plpgsql set search_path = public, private as $$
declare c public.practice_clients; v_name text; v_id uuid;
begin
  select * into c from practice_clients where id = p_client;
  if c.id is null or c.intake_id is not null or c.practice_id is null or c.org_id is null then return c.intake_id; end if;
  select coalesce(nullif(trim(c.business_name), ''), trim(o.name)) into v_name from orgs o where o.id = c.org_id;
  -- A one-letter business name is still a name to confirm.
  v_name := case when length(v_name) >= 2 then left(v_name, 160) else coalesce(v_name, '') || ' (name to confirm)' end;
  insert into practice_intakes (practice_id, status, mode_requested, legal_name, rc_number, tax_id, dd_incomplete, client_id, org_id)
  select c.practice_id, 'engaged', c.mode, v_name, left(o.rc_number, 40), left(o.tin, 40), true, c.id, c.org_id
  from orgs o where o.id = c.org_id
  returning id into v_id;
  update practice_clients set intake_id = v_id where id = c.id;
  return v_id;
end $$;

-- Draft intakes for the active client links that have none; how many were made. Run once below for the links made before
-- intakes existed.
create or replace function private.intake_backfill() returns integer
language plpgsql set search_path = public, private as $$
declare v_client uuid; v_n integer := 0;
begin
  for v_client in select id from practice_clients
                  where status = 'active' and intake_id is null and practice_id is not null and org_id is not null order by created_at, id loop
    perform private.intake_for_client(v_client);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- A client link that becomes active engages its intake, which must be this practice's and cleared (not declined, and
-- not changed or found to conflict since) unless the link was engaged on it before: otherwise the link does not go ahead.
-- A link with no intake gets a draft one.
-- A link that ends or is declined dates its intake's retention (never earlier than a date it already has).
create or replace function private.practice_clients_intake() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare x public.practice_intakes;
begin
  if new.practice_id is null or (tg_op = 'UPDATE' and new.status is not distinct from old.status) then return null; end if;
  if new.status = 'active' then
    if new.intake_id is null then
      perform private.intake_for_client(new.id);
      return null;
    end if;
    select * into x from practice_intakes where id = new.intake_id for update;
    if x.practice_id is distinct from new.practice_id then raise exception 'That due-diligence intake belongs to another practice.'; end if;
    -- (A link taken up again keeps the intake it was engaged on, cleared or not.)
    if not (x.status = 'engaged' and x.client_id = new.id) and (x.status = 'declined' or not private.intake_cleared(x)) then
      raise exception 'This cannot go ahead yet: the practice has not finished its checks on the business. Ask the practice about it.';
    end if;
    update practice_intakes set status = 'engaged', org_id = new.org_id, client_id = new.id, retain_until = null, updated_at = now() where id = x.id;
    perform private.intake_settle(x.id);
  elsif new.status in ('ended', 'declined') and new.intake_id is not null then
    update practice_intakes set retain_until = greatest(retain_until, private.retain_date(new.retention_years)), updated_at = now()
    where id = new.intake_id;
  end if;
  return null;
end $$;

create trigger practice_clients_intake after insert or update of status on public.practice_clients
  for each row execute function private.practice_clients_intake();

do $$
begin
  perform private.intake_backfill();
end $$;

-- ---------------------------------------------------------------------------
-- 5. Practice files in the documents bucket
-- ---------------------------------------------------------------------------
-- practice/<pid>/letters/...: the practice's active people; practice/<pid>/intake/...: its active partners and managers (who
-- keep the intakes); practice/<pid>/exports/...: its active partners. Called by the bucket's policies as the signed-in
-- person, so it reads the practice as its owner.
create or replace function private.practice_file_ok(p_name text) returns boolean
language sql stable security definer set search_path = public, private as $$
  select coalesce(p_name ~ '^practice/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/(intake|letters|exports)/[^/]', false)
    and exists (select 1 from practice_members pm
                where pm.practice_id::text = split_part(p_name, '/', 2) and pm.user_id = auth.uid() and pm.status = 'active'
                  and case split_part(p_name, '/', 3) when 'exports' then pm.role = 'partner'
                                                      when 'intake' then pm.role in ('partner', 'manager') else true end)
$$;

do $$
begin
  if to_regclass('storage.objects') is not null then
    drop policy if exists "practice files read by practice members" on storage.objects;
    create policy "practice files read by practice members" on storage.objects for select to authenticated
      using (bucket_id = 'documents' and (storage.foldername(name))[1] = 'practice' and private.practice_file_ok(name));
    drop policy if exists "practice files upload by practice members" on storage.objects;
    create policy "practice files upload by practice members" on storage.objects for insert to authenticated
      with check (bucket_id = 'documents' and (storage.foldername(name))[1] = 'practice' and private.practice_file_ok(name));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. The portal's calls (partners and managers unless said)
-- ---------------------------------------------------------------------------
-- One intake in full. letters: its engagement letters (none until letters are recorded).
create or replace function public.practice_intake(p_intake uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.practice_intakes;
begin
  i := private.intake_require(p_intake);
  return private.intake_json(i, true) || jsonb_build_object('letters', '[]'::jsonb);
end $$;

-- The practice's intakes, newest first. p: {status?: draft|engaged|declined}.
create or replace function public.practice_intakes(p_practice uuid, p jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_status text := nullif(p->>'status', '');
begin
  perform private.practice_require(p_practice, true);
  return (select coalesce(jsonb_agg(private.intake_json(x, false) order by x.created_at desc, x.id), '[]'::jsonb)
          from practice_intakes x where x.practice_id = p_practice and (v_status is null or x.status = v_status));
end $$;

-- Starts or changes an intake. p: {id?, mode_requested, legal_name, entity_type, rc_number, tax_id, address, industry,
-- risk_rating, risk_reason, people?: [{kind, name, role, ownership_pct, nationality, is_pep, id_type, id_last4}]}; a key
-- left out keeps its value, and people given replace those recorded. An ID number is recorded only as its last 4
-- characters. A politically exposed person makes the risk high. A change to the name, RC number, Tax ID or people needs a
-- new conflicts check (and a new name or mode a new declaration, which names the client and the mandate). While an
-- invitation carrying the intake waits, those changes, removing the risk rating or leaving involved mode wait for it to
-- be withdrawn. An intake kept as the record of an engagement (private.intake_kept) is not changed.
create or replace function public.practice_intake_save(p_practice uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.practice_members; i public.practice_intakes; x jsonb; v_people jsonb := '[]'; v_old_people jsonb := '[]';
  v_name text; v_mode text; v_type text; v_rc text; v_tax text; v_address text; v_industry text; v_risk text; v_reason text;
  v_pname text; v_prole text; v_pnat text; v_kind text; v_idtype text; v_last4 text; v_pct numeric;
  v_people_changed boolean := false; v_edit boolean; v_pep boolean; v_withdraw boolean;
begin
  m := private.practice_require(p_practice, true);
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'Nothing to save.'; end if;
  if nullif(p->>'id', '') is not null then
    select * into i from practice_intakes where id = private.uuid_of(p->>'id') and practice_id = p_practice for update;
    if i.id is null then raise exception 'Intake not found.'; end if;
    if i.status = 'declined' then raise exception 'This intake was declined after the conflicts check. Start a new one.'; end if;
    if private.intake_kept(i) then raise exception 'This intake is kept as the record of the engagement. Start a new intake to record changes.'; end if;
  end if;

  -- The intake's details: those given, else as they were.
  v_name := case when p ? 'legal_name' then nullif(trim(p->>'legal_name'), '') else i.legal_name end;
  v_mode := case when p ? 'mode_requested' then nullif(p->>'mode_requested', '') else i.mode_requested end;
  v_type := case when p ? 'entity_type' then nullif(p->>'entity_type', '') else i.entity_type end;
  v_rc := case when p ? 'rc_number' then nullif(trim(p->>'rc_number'), '') else i.rc_number end;
  v_tax := case when p ? 'tax_id' then nullif(trim(p->>'tax_id'), '') else i.tax_id end;
  v_address := case when p ? 'address' then nullif(trim(p->>'address'), '') else i.address end;
  v_industry := case when p ? 'industry' then nullif(trim(p->>'industry'), '') else i.industry end;
  v_risk := case when p ? 'risk_rating' then nullif(p->>'risk_rating', '') else i.risk_rating end;
  v_reason := case when p ? 'risk_reason' then nullif(trim(p->>'risk_reason'), '') else i.risk_reason end;
  if v_name is null or length(v_name) not between 2 and 160 then raise exception 'Enter the business''s registered name (2 to 160 characters).'; end if;
  if coalesce(v_mode, 'involved') not in ('involved', 'full') then raise exception 'Choose involved or full mandate.'; end if;
  if v_type is not null and v_type not in ('company', 'business_name', 'incorporated_trustees', 'partnership', 'individual') then
    raise exception 'Choose the kind of business.';
  end if;
  if length(v_rc) > 40 or length(v_tax) > 40 then raise exception 'That RC number or Tax ID is too long.'; end if;
  if length(v_address) > 300 then raise exception 'Keep the address under 300 characters.'; end if;
  if length(v_industry) > 80 then raise exception 'Keep the industry under 80 characters.'; end if;
  if v_risk is not null and v_risk not in ('low', 'medium', 'high') then raise exception 'Choose a low, medium or high risk.'; end if;
  if length(v_reason) > 1000 then raise exception 'Keep the reason for the risk under 1,000 characters.'; end if;

  -- The people, checked before anything is kept.
  if p ? 'people' then
    if jsonb_typeof(p->'people') is distinct from 'array' then raise exception 'List the people as a list.'; end if;
    if jsonb_array_length(p->'people') > 100 then raise exception 'Record up to 100 people.'; end if;
    for x in select e from jsonb_array_elements(p->'people') e loop
      if jsonb_typeof(x) is distinct from 'object' then raise exception 'Each person needs a name.'; end if;
      v_pname := nullif(trim(x->>'name'), ''); v_prole := nullif(trim(x->>'role'), ''); v_pnat := nullif(trim(x->>'nationality'), '');
      v_last4 := nullif(trim(x->>'id_last4'), '');
      if x ?| array['id_number', 'nin', 'bvn'] or v_last4 !~ '^[A-Za-z0-9]{4}$'
         or private.has_id_number(v_pname) or private.has_id_number(v_prole) or private.has_id_number(v_pnat) then
        raise exception 'Record only the last 4 characters of an ID number.';
      end if;
      v_kind := coalesce(nullif(x->>'kind', ''), 'director');
      if v_kind not in ('director', 'beneficial_owner', 'related') then raise exception 'Choose director, beneficial owner or related person.'; end if;
      if v_pname is null or length(v_pname) not between 2 and 120 then raise exception 'Enter each person''s name (2 to 120 characters).'; end if;
      if length(v_prole) > 80 then raise exception 'Keep %''s role under 80 characters.', v_pname; end if;
      if length(v_pnat) > 60 then raise exception 'Keep %''s nationality under 60 characters.', v_pname; end if;
      v_pct := null;
      if nullif(trim(x->>'ownership_pct'), '') is not null then
        if trim(x->>'ownership_pct') !~ '^[0-9]{1,3}(\.[0-9]+)?$' or trim(x->>'ownership_pct')::numeric > 100 then
          raise exception 'Ownership is a percentage from 0 to 100.';
        end if;
        v_pct := round(trim(x->>'ownership_pct')::numeric, 2);
      end if;
      if jsonb_typeof(x->'is_pep') not in ('boolean', 'null') and coalesce(x->>'is_pep', '') not in ('true', 'false') then
        raise exception 'Say yes or no to whether % is a politically exposed person.', v_pname;
      end if;
      v_idtype := nullif(x->>'id_type', '');
      if v_idtype is not null and v_idtype not in ('nin', 'bvn', 'passport', 'drivers_licence', 'voters_card', 'cac', 'other') then
        raise exception 'Choose the kind of ID.';
      end if;
      v_people := v_people || jsonb_build_array(jsonb_build_object('kind', v_kind, 'name', v_pname, 'role', v_prole, 'ownership_pct', v_pct,
        'nationality', v_pnat, 'is_pep', coalesce((x->>'is_pep')::boolean, false), 'id_type', v_idtype, 'id_last4', v_last4));
    end loop;
    select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'name', name, 'role', role, 'ownership_pct', ownership_pct, 'nationality', nationality,
        'is_pep', is_pep, 'id_type', id_type, 'id_last4', id_last4)), '[]'::jsonb)
      into v_old_people from practice_intake_people where intake_id = i.id;
    v_people_changed := (select coalesce(jsonb_agg(e order by e::text), '[]'::jsonb) from jsonb_array_elements(v_people) e)
      is distinct from (select coalesce(jsonb_agg(e order by e::text), '[]'::jsonb) from jsonb_array_elements(v_old_people) e);
    v_pep := exists (select 1 from jsonb_array_elements(v_people) e where (e->>'is_pep')::boolean);
  else
    v_pep := coalesce(i.pep_present, false);
  end if;
  if v_pep then v_risk := 'high'; end if;
  v_edit := i.id is null or v_people_changed or v_name is distinct from i.legal_name or v_rc is distinct from i.rc_number or v_tax is distinct from i.tax_id;
  v_withdraw := v_name is distinct from i.legal_name or coalesce(v_mode, i.mode_requested) is distinct from i.mode_requested;
  if i.id is not null and private.intake_invited(i.id) and (v_edit or v_risk is null or coalesce(v_mode, i.mode_requested) <> 'involved') then
    raise exception 'Withdraw the invitation first: it was sent on this intake as it stands.';
  end if;

  if i.id is null then
    insert into practice_intakes (practice_id, mode_requested, legal_name, entity_type, rc_number, tax_id, address, industry, risk_rating, risk_reason,
      pep_present, created_by)
    values (p_practice, coalesce(v_mode, 'involved'), v_name, v_type, v_rc, v_tax, v_address, v_industry, v_risk, v_reason, v_pep, auth.uid())
    returning * into i;
  else
    update practice_intakes set mode_requested = coalesce(v_mode, mode_requested), legal_name = v_name, entity_type = v_type, rc_number = v_rc,
      tax_id = v_tax, address = v_address, industry = v_industry, risk_rating = v_risk, risk_reason = v_reason, pep_present = v_pep,
      conflict_status = case when v_edit then 'pending' else conflict_status end,
      conflict_note = case when v_edit then null else conflict_note end,
      conflict_decided_by = case when v_edit then null else conflict_decided_by end,
      conflict_decided_at = case when v_edit then null else conflict_decided_at end,
      edited_at = case when v_edit then now() else edited_at end,
      authority_declared_by = case when v_withdraw then null else authority_declared_by end,
      authority_declared_at = case when v_withdraw then null else authority_declared_at end,
      authority_statement = case when v_withdraw then null else authority_statement end,
      authority_doc_path = case when v_withdraw then null else authority_doc_path end,
      updated_at = now()
    where id = i.id
    returning * into i;
  end if;
  if v_people_changed then
    perform set_config('counta.intake_save', 'on', true);
    delete from practice_intake_people where intake_id = i.id;
    perform set_config('counta.intake_save', '', true);
    insert into practice_intake_people (intake_id, practice_id, kind, name, role, ownership_pct, nationality, is_pep, id_type, id_last4)
    select i.id, i.practice_id, e->>'kind', e->>'name', e->>'role', (e->>'ownership_pct')::numeric, e->>'nationality', (e->>'is_pep')::boolean,
      e->>'id_type', e->>'id_last4'
    from jsonb_array_elements(v_people) e;
  end if;
  perform private.intake_settle(i.id);
  return public.practice_intake(i.id);
end $$;

-- A supporting document already uploaded to the intake's folder. p: {path, name?, sha256, kind?: cac|id|address|other}.
create or replace function public.practice_intake_doc_add(p_intake uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.practice_intakes; m public.practice_members; v_path text := trim(coalesce(p->>'path', ''));
  v_sha text := lower(trim(coalesce(p->>'sha256', ''))); v_kind text := coalesce(nullif(p->>'kind', ''), 'other'); v_name text;
begin
  i := private.intake_require(p_intake, true);
  m := private.practice_me(i.practice_id);
  if v_path not like 'practice/' || i.practice_id || '/intake/' || i.id || '/_%' or length(v_path) > 500 then
    raise exception 'Upload the file to the intake''s folder first.';
  end if;
  if v_sha !~ '^[0-9a-f]{64}$' then raise exception 'The file''s SHA-256 fingerprint is missing.'; end if;
  if v_kind not in ('cac', 'id', 'address', 'other') then raise exception 'Choose CAC, ID, address or other.'; end if;
  v_name := left(coalesce(nullif(trim(p->>'name'), ''), regexp_replace(v_path, '^.*/', '')), 200);
  if exists (select 1 from practice_intake_docs where intake_id = i.id and path = v_path) then raise exception 'That file is on the intake already.'; end if;
  insert into practice_intake_docs (intake_id, practice_id, kind, name, path, sha256, added_by)
  values (i.id, i.practice_id, v_kind, v_name, v_path, v_sha, m.id);
  update practice_intakes set updated_at = now() where id = i.id;
  return public.practice_intake(i.id);
end $$;

-- The other side of a client's matter, for the conflicts check. p: {id?, client_id?, name, rc_number?, note?, remove?}.
create or replace function public.practice_opposing_save(p_practice uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.practice_members; op public.practice_opposing_parties; v_client uuid; v_name text; v_rc text; v_note text;
begin
  m := private.practice_require(p_practice, true);
  if jsonb_typeof(p) is distinct from 'object' then raise exception 'Nothing to save.'; end if;
  if nullif(p->>'id', '') is not null then
    select * into op from practice_opposing_parties where id = private.uuid_of(p->>'id') and practice_id = p_practice for update;
    if op.id is null then raise exception 'Opposing party not found.'; end if;
    if jsonb_typeof(p->'remove') not in ('boolean', 'null') and coalesce(p->>'remove', '') not in ('true', 'false') then
      raise exception 'Say true or false to remove the opposing party.';
    end if;
    if coalesce((p->>'remove')::boolean, false) then
      delete from practice_opposing_parties where id = op.id;
      return jsonb_build_object('id', op.id, 'removed', true);
    end if;
  end if;
  v_client := case when p ? 'client_id' then private.uuid_of(nullif(p->>'client_id', '')) else op.client_id end;
  if nullif(p->>'client_id', '') is not null and (v_client is null
     or not exists (select 1 from practice_clients where id = v_client and practice_id = p_practice)) then
    raise exception 'Client not found.';
  end if;
  v_name := case when p ? 'name' then nullif(trim(p->>'name'), '') else op.name end;
  v_rc := case when p ? 'rc_number' then nullif(trim(p->>'rc_number'), '') else op.rc_number end;
  v_note := case when p ? 'note' then nullif(trim(p->>'note'), '') else op.note end;
  if v_name is null or length(v_name) not between 2 and 160 then raise exception 'Enter the opposing party''s name (2 to 160 characters).'; end if;
  if length(v_rc) > 40 then raise exception 'That RC number is too long.'; end if;
  if length(v_note) > 500 then raise exception 'Keep the note under 500 characters.'; end if;
  if op.id is null then
    insert into practice_opposing_parties (practice_id, client_id, name, rc_number, note, created_by)
    values (p_practice, v_client, v_name, v_rc, v_note, m.id) returning * into op;
  else
    update practice_opposing_parties set client_id = v_client, name = v_name, rc_number = v_rc, note = v_note, updated_at = now()
    where id = op.id returning * into op;
  end if;
  return jsonb_build_object('id', op.id, 'client_id', op.client_id, 'name', op.name, 'rc_number', op.rc_number, 'note', op.note);
end $$;

-- Runs the conflicts check: hits or none, dated now. A decision on an earlier check no longer stands. It may run while an
-- invitation waits: if it finds something, the invitation cannot be accepted until a partner clears it.
create or replace function public.practice_conflict_run(p_intake uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.practice_intakes; v_n integer;
begin
  i := private.intake_require(p_intake, true);
  if i.status = 'declined' then raise exception 'This intake was declined after the conflicts check.'; end if;
  if private.intake_kept(i) then raise exception 'This intake is kept as the record of the engagement. Start a new intake to check again.'; end if;
  v_n := private.conflict_scan(i.id);
  update practice_intakes set checked_at = now(), conflict_status = case when v_n > 0 then 'hits' else 'none' end,
    conflict_note = null, conflict_decided_by = null, conflict_decided_at = null, updated_at = now()
  where id = i.id;
  perform private.intake_settle(i.id);
  return public.practice_intake(i.id);
end $$;

-- A partner's outcome on what the check found. p: {outcome: cleared|refused, note (10 characters or more)}. Refused: the
-- intake is declined, kept for five years, and any invitation carrying it is withdrawn. A business already taken on is
-- not refused here: its engagement is ended instead.
create or replace function public.practice_conflict_decide(p_intake uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.practice_intakes; m public.practice_members; v_outcome text := p->>'outcome'; v_note text := trim(coalesce(p->>'note', ''));
begin
  i := private.intake_require(p_intake, true);
  m := private.practice_me(i.practice_id);
  if m.role <> 'partner' then raise exception 'Only a partner records the outcome of the conflicts check.' using errcode = '42501'; end if;
  if coalesce(v_outcome, '') not in ('cleared', 'refused') then raise exception 'Choose cleared or refused.'; end if;
  if length(v_note) < 10 then raise exception 'Write a note of at least 10 characters.'; end if;
  if length(v_note) > 1000 then raise exception 'Keep the note under 1,000 characters.'; end if;
  if i.conflict_status in ('cleared', 'refused') then raise exception 'The outcome of this check is recorded. Run the check again to decide afresh.'; end if;
  if i.conflict_status = 'none' then raise exception 'The conflicts check found nothing to decide.'; end if;
  if i.conflict_status <> 'hits' or not coalesce(i.checked_at >= i.edited_at, false) then
    raise exception 'Run the conflicts check first: the intake changed after it.';
  end if;
  if v_outcome = 'refused' and i.status = 'engaged' then
    raise exception 'This business is already a client: end the engagement instead of refusing it.';
  end if;
  update practice_intakes set conflict_status = v_outcome, conflict_note = v_note, conflict_decided_by = m.id, conflict_decided_at = now(),
    status = case when v_outcome = 'refused' then 'declined' else status end,
    retain_until = case when v_outcome = 'refused' then private.retain_date(5) else retain_until end,
    updated_at = now()
  where id = i.id;
  if v_outcome = 'refused' then
    update practice_clients set status = 'declined', token_hash = null, ended_at = now(), ended_by = auth.uid()
    where intake_id = i.id and status = 'invited';
  end if;
  perform private.intake_settle(i.id);
  return public.practice_intake(i.id);
end $$;

-- Whether the conflicts check also looks among the active clients' customers and suppliers (a partner's choice).
create or replace function public.practice_set_conflict_scan(p_practice uuid, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.practice_members;
begin
  m := private.practice_require(p_practice, true);
  if m.role <> 'partner' then raise exception 'Only a partner changes how the conflicts check works.' using errcode = '42501'; end if;
  update practices set conflict_scan_books = coalesce(p_on, false), updated_at = now() where id = p_practice;
  return public.practice_home(p_practice);
end $$;

-- A partner declares that the firm holds the client's written authority for a full mandate. p: {doc_path?} (the signed
-- authority, uploaded to the intake's folder).
create or replace function public.practice_intake_declare(p_intake uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare i public.practice_intakes; m public.practice_members; v_firm text; v_doc text := nullif(trim(coalesce(p->>'doc_path', '')), '');
begin
  i := private.intake_require(p_intake, true);
  m := private.practice_me(i.practice_id);
  if m.role <> 'partner' then raise exception 'Only a partner makes the declaration.' using errcode = '42501'; end if;
  if i.status = 'declined' then raise exception 'This intake was declined after the conflicts check.'; end if;
  if private.intake_kept(i) then raise exception 'This intake is kept as the record of the engagement.'; end if;
  if i.mode_requested <> 'full' then raise exception 'The declaration is for a full mandate.'; end if;
  if v_doc is not null and v_doc not like 'practice/' || i.practice_id || '/intake/' || i.id || '/_%' then
    raise exception 'Upload the signed authority to the intake''s folder first.';
  end if;
  select name into v_firm from practices where id = i.practice_id;
  update practice_intakes set authority_declared_by = m.id, authority_declared_at = now(), authority_doc_path = v_doc,
    authority_statement = format('I confirm that %s holds the written authority of %s to set up and run its accounting records and tax affairs on its '
      || 'behalf under full mandate, as set out in the engagement letter, and that I am a partner of %s.', v_firm, i.legal_name, v_firm),
    updated_at = now()
  where id = i.id;
  return public.practice_intake(i.id);
end $$;

-- ---------------------------------------------------------------------------
-- 7. Inviting a business owner needs the due diligence done
-- ---------------------------------------------------------------------------
-- p: {email, name, business_name, services, billing, note, intake_id}: the practice asks a business owner to connect
-- their business, once its intake (involved) is cleared. The invitation carries the intake; the business name defaults
-- to the intake's.
create or replace function public.practice_invite_client(p_practice uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare m public.practice_members; i public.practice_intakes; v_email text := lower(trim(coalesce(p->>'email', ''))); v_id uuid; v_services text[];
begin
  m := private.practice_require(p_practice, true);
  select * into i from practice_intakes where id = private.uuid_of(p->>'intake_id') and practice_id = p_practice for update;
  if i.id is null or i.mode_requested <> 'involved' or i.status = 'declined' or not private.intake_cleared(i) then
    raise exception 'Finish the due diligence and conflicts check first.';
  end if;
  if exists (select 1 from practice_clients where intake_id = i.id and status in ('invited', 'active')) then
    raise exception 'This business has been invited already.';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter the business owner''s email address.'; end if;
  if (select count(*) from practice_clients where practice_id = p_practice and created_at > now() - interval '1 day') >= 50 then
    raise exception 'That is fifty invitations today. Try again tomorrow.';
  end if;
  select coalesce(array_agg(distinct x) filter (where x in ('bookkeeping', 'vat', 'wht', 'cit', 'statements', 'payroll', 'advisory')), '{bookkeeping,vat,wht,cit,statements}')
    into v_services from jsonb_array_elements_text(coalesce(p->'services', '[]'::jsonb)) x;
  if exists (select 1 from practice_clients where practice_id = p_practice and status = 'invited' and lower(invite_email) = v_email) then
    raise exception 'An invitation to % is already waiting. Send it again from the list.', v_email;
  end if;
  insert into practice_clients (practice_id, status, initiated_by, invite_email, invite_name, business_name, services, billing, note, created_by, intake_id)
  values (p_practice, 'invited', 'practice', v_email, nullif(left(trim(p->>'name'), 80), ''),
    coalesce(nullif(left(trim(p->>'business_name'), 120), ''), left(i.legal_name, 120)), v_services,
    case when p->>'billing' = 'practice' then 'practice' else 'business' end, nullif(left(trim(p->>'note'), 500), ''), auth.uid(), i.id)
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 8. The activity log leaves intakes alone: they are the practice's records, not the business's
-- ---------------------------------------------------------------------------
create or replace function private.activity_exempt() returns text[]
language sql immutable set search_path = public, private as $$
  select array['activity_log', 'messages', 'notifications', 'alert_log', 'usage_events', 'ai_logs', 'shop_hits', 'payment_events', 'org_counters',
    'stock_levels', 'agent_runs', 'guide_progress', 'lookup_failures', 'sso_logins', 'whatsapp_sessions', 'chat_links', 'voice_calls',
    'integration_events', 'prism_callbacks', 'kyc_profiles', 'practice_intakes']
$$;

-- ---------------------------------------------------------------------------
-- 9. Grants
-- ---------------------------------------------------------------------------
-- core.sql grants every private function to authenticated: the helpers this migration creates or redefines are not
-- callable by the signed-in person, except practice_file_ok, which the bucket's policies call as that person.
revoke all on function private.fold_name(text), private.norm_id(text), private.has_id_number(text), private.company_name_score(text, text),
  private.uuid_of(text), private.retain_date(int), private.intake_cleared(public.practice_intakes), private.intake_kept(public.practice_intakes),
  private.intake_invited(uuid), private.intake_require(uuid, boolean), private.intake_settle(uuid), private.intake_for_client(uuid),
  private.intake_backfill(),
  private.intake_json(public.practice_intakes, boolean), private.conflict_scan(uuid), private.practice_intakes_retention(),
  private.practice_clients_intake(), private.activity_exempt()
  from public, anon, authenticated;
revoke execute on function private.practice_file_ok(text) from public, anon;
grant execute on function private.practice_file_ok(text) to authenticated;
revoke execute on function public.practice_intake(uuid), public.practice_intakes(uuid, jsonb), public.practice_intake_save(uuid, jsonb),
  public.practice_intake_doc_add(uuid, jsonb), public.practice_opposing_save(uuid, jsonb), public.practice_conflict_run(uuid),
  public.practice_conflict_decide(uuid, jsonb), public.practice_set_conflict_scan(uuid, boolean), public.practice_intake_declare(uuid, jsonb)
  from public, anon;
grant execute on function public.practice_intake(uuid), public.practice_intakes(uuid, jsonb), public.practice_intake_save(uuid, jsonb),
  public.practice_intake_doc_add(uuid, jsonb), public.practice_opposing_save(uuid, jsonb), public.practice_conflict_run(uuid),
  public.practice_conflict_decide(uuid, jsonb), public.practice_set_conflict_scan(uuid, boolean), public.practice_intake_declare(uuid, jsonb)
  to authenticated;
