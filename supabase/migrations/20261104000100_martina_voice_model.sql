-- Martina's voice model, chosen in the admin portal (Martina and voices). Eleven v4 Turbo is what she has used so far: the most
-- natural, and the only one that takes expressive cues. Turbo v2.5 and Flash v2.5 read plainly and never add sighs or laughs.
-- The voice function reads the choice when it syncs her agents with ElevenLabs. Nothing else changes.

-- The default, beside her manner and her voice.
create or replace function private.setting_defaults(p_key text) returns jsonb
language sql immutable set search_path = public as $$
  select case p_key
    when 'martina' then '{"tone": "calm", "default_voice_id": null, "voice_model": "eleven_v4_turbo"}'::jsonb
    when 'limits' then '{"guide_day": 8, "guide_week": 25, "assistant_day": 30, "assistant_week": 150,
      "voice_org_phrases": 600, "voice_org_chars": 60000, "voice_user_phrases": 60, "voice_user_chars": 6000,
      "lookups": {"search": 20, "profile": 6, "tin": 6, "status_report": 3, "web": 8, "document": 6, "nin": 5, "nin_slip": 4, "product": 200}}'::jsonb
    when 'alerts' then '{"tax_deadline": {"push": true, "email": true, "whatsapp": true, "call": true, "days_before": [7, 3, 1], "message_days_before": [3, 1], "call_days_before": 1},
      "invoices": {"push": true, "email": true, "whatsapp": true, "due_soon_days": 3, "digest_weekday": 1},
      "confirm": {"push_from_day": 10, "email": true, "whatsapp": true, "message_days": [15, 19]},
      "customer_calls": {"enabled": true, "min_days_overdue": 7, "min_amount": 10000, "per_org_per_day": 5, "repeat_days": 7, "weekdays_only": true},
      "calls": {"hours": [9, 17]}}'::jsonb
    when 'switches' then '{"new_businesses": true, "martina": true, "phone_calls": true, "payment_voice": true, "ai_reading": true,
      "email": true, "whatsapp": true, "payments": true}'::jsonb
    else '{}'::jsonb end
$$;

-- The admin portal saves it like her manner: one of the three models, nothing else.
create or replace function public.admin_save_setting(p_key text, p_value jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_cur jsonb := private.setting(p_key); v_new jsonb; k text; x jsonb; n numeric; v_old jsonb; g text; gx jsonb; e jsonb; v_def jsonb;
begin
  perform private.require_staff();
  if p_key not in ('martina', 'limits', 'switches', 'alerts') then raise exception 'Unknown setting.'; end if;
  if jsonb_typeof(coalesce(p_value, 'null'::jsonb)) <> 'object' then raise exception 'Nothing to save.'; end if;
  v_new := v_cur;
  if p_key = 'martina' then
    if p_value ? 'tone' then
      if p_value->>'tone' not in ('calm', 'warm', 'lively') then raise exception 'Choose calm, warm or lively.'; end if;
      v_new := v_new || jsonb_build_object('tone', p_value->>'tone');
    end if;
    if p_value ? 'default_voice_id' then
      if nullif(p_value->>'default_voice_id', '') is not null
         and not exists (select 1 from tts_voices where voice_id = p_value->>'default_voice_id' and active) then
        raise exception 'Choose one of the voices on offer.';
      end if;
      v_new := v_new || jsonb_build_object('default_voice_id', nullif(p_value->>'default_voice_id', ''));
    end if;
    if p_value ? 'voice_model' then
      if coalesce(p_value->>'voice_model', '') not in ('eleven_v4_turbo', 'eleven_turbo_v2_5', 'eleven_flash_v2_5') then
        raise exception 'Choose Eleven v4 Turbo, Turbo v2.5 or Flash v2.5.';
      end if;
      v_new := v_new || jsonb_build_object('voice_model', p_value->>'voice_model');
    end if;
  elsif p_key = 'limits' then
    for k, x in select * from jsonb_each(p_value) loop
      if k = 'lookups' then
        if jsonb_typeof(x) <> 'object' then raise exception 'Unknown limit.'; end if;
        for k, x in select * from jsonb_each(p_value->'lookups') loop
          if not (private.setting_defaults('limits')->'lookups' ? k) then raise exception 'Unknown lookup: %.', k; end if;
          begin n := (x #>> '{}')::numeric; exception when others then raise exception 'Limits are whole numbers.'; end;
          if n is null or n <> trunc(n) or n < 0 or n > 100000 then raise exception 'Limits are whole numbers from 0 to 100,000.'; end if;
          v_new := jsonb_set(v_new, array['lookups', k], to_jsonb(n::int));
        end loop;
      else
        if not (private.setting_defaults('limits') ? k) then raise exception 'Unknown limit: %.', k; end if;
        begin n := (x #>> '{}')::numeric; exception when others then raise exception 'Limits are whole numbers.'; end;
        if n is null or n <> trunc(n) or n < 0 or n > 10000000 then raise exception 'Limits are whole numbers from 0 to 10,000,000.'; end if;
        v_new := v_new || jsonb_build_object(k, n::int);
      end if;
    end loop;
    if (v_new->>'guide_week')::int < (v_new->>'guide_day')::int or (v_new->>'assistant_week')::int < (v_new->>'assistant_day')::int then
      raise exception 'A week''s limit cannot be smaller than a day''s.';
    end if;
  elsif p_key = 'alerts' then
    -- Only the settings that exist, each as the kind of value it is: on/off, a whole number, or a list of whole numbers.
    v_def := private.setting_defaults('alerts');
    for g, gx in select * from jsonb_each(p_value) loop
      if not (v_def ? g) or jsonb_typeof(gx) <> 'object' then raise exception 'Unknown alert setting: %.', g; end if;
      for k, x in select * from jsonb_each(gx) loop
        if not (v_def->g ? k) then raise exception 'Unknown alert setting: %.%.', g, k; end if;
        if jsonb_typeof(x) <> jsonb_typeof(v_def->g->k) then raise exception 'Alert setting %.% must be %.', g, k,
          case jsonb_typeof(v_def->g->k) when 'boolean' then 'on or off' when 'number' then 'a whole number' else 'a list of whole numbers' end; end if;
        if jsonb_typeof(x) = 'number' and ((x #>> '{}')::numeric <> trunc((x #>> '{}')::numeric) or (x #>> '{}')::numeric < 0 or (x #>> '{}')::numeric > 100000000) then
          raise exception 'Alert setting %.% must be a whole number from 0.', g, k;
        end if;
        if jsonb_typeof(x) = 'array' then
          for e in select * from jsonb_array_elements(x) loop
            if jsonb_typeof(e) <> 'number' or (e #>> '{}')::numeric <> trunc((e #>> '{}')::numeric) or (e #>> '{}')::numeric < 0 or (e #>> '{}')::numeric > 60 then
              raise exception 'Alert setting %.% is a list of whole numbers from 0 to 60.', g, k;
            end if;
          end loop;
          if jsonb_array_length(x) > 10 then raise exception 'Alert setting %.% takes at most 10 numbers.', g, k; end if;
        end if;
        v_new := jsonb_set(v_new, array[g, k], x);
      end loop;
    end loop;
    if jsonb_array_length(v_new->'calls'->'hours') <> 2 or (v_new->'calls'->'hours'->>0)::int >= (v_new->'calls'->'hours'->>1)::int
       or (v_new->'calls'->'hours'->>1)::int > 22 or (v_new->'calls'->'hours'->>0)::int < 7 then
      raise exception 'Calling hours are a start and an end between 7 and 22, the start first.';
    end if;
    if (v_new->'invoices'->>'digest_weekday')::int not between 1 and 7 then raise exception 'The weekly email day is 1 (Monday) to 7 (Sunday).'; end if;
  else
    for k, x in select * from jsonb_each(p_value) loop
      if not (k = any (private.feature_keys())) then raise exception 'Unknown switch: %.', k; end if;
      if jsonb_typeof(x) <> 'boolean' then raise exception 'Switches are on or off.'; end if;
      v_new := v_new || jsonb_build_object(k, x);
    end loop;
  end if;
  select value into v_old from platform_settings where key = p_key;
  insert into platform_settings (key, value, updated_by, updated_at) values (p_key, v_new, auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  perform private.audit('save_' || p_key, p_key, jsonb_build_object('from', coalesce(v_old, v_cur), 'to', v_new));
  return v_new;
end $$;
