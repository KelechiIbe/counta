-- Choosing the guide's language sets the business's voice language for its owner (or a manager).
-- setup
insert into guide_progress (user_id, org_id) select user_id, org_id from members where org_id = tests.id('org') and user_id is not null on conflict (user_id) do update set org_id = excluded.org_id;
-- call
select public.guide_language('pcm')
select voice_lang from orgs where id = tests.id('org')
