begin;

-- EPUB spine positions are compact chapter metadata. Keep the database-side RPC guard aligned
-- with the Worker allowlist so direct service-role callers retain the same bounded schema.
create or replace function public.sync_v2_json_is_bounded(
  p_value jsonb,
  p_depth integer,
  p_schema_key text
)
returns boolean
language plpgsql
immutable
strict
set search_path = public
as $$
declare
  v_item jsonb;
  v_key text;
  v_nested jsonb;
  v_allowed text[];
  v_normalized_key text;
begin
  if p_depth > 8 then return false; end if;
  case jsonb_typeof(p_value)
    when 'string' then return octet_length(p_value #>> '{}') <= 65536;
    when 'number', 'boolean', 'null' then return true;
    when 'array' then
      if jsonb_array_length(p_value) > 4096 then return false; end if;
      for v_item in select value from jsonb_array_elements(p_value)
      loop
        if not public.sync_v2_json_is_bounded(v_item, p_depth + 1, p_schema_key) then
          return false;
        end if;
      end loop;
      return true;
    when 'object' then
      if p_depth > 0 then
        v_allowed := case p_schema_key
          when 'chapters' then array['localId','index','title','duration','startTime','ebookSectionIndex']
          when 'result' then array['id','kind','status','language','model','bookID','bookTitle','chapterID','chapterTitle','source','text','context','timestamp','createdAt','decidedAt','replacedText','replacedModel','promptVersion','modelPolicyHash','sharedCacheEntryID','targetID','privateContentJSON']
          when 'vocabulary' then array['id','bookID','chapterID','bookTitle','chapterTitle','word','translation','definition','context','timestamp','addedAt','category','segmentID','wordID','spokenText','ebookText','translationLanguage','translationModel','sourceLanguage','canonicalForm','partOfSpeech','senseID','canonicalizationSource','canonicalizationConfidence','canonicalizationStatus','canonicalizationTraceID','captureSource','reviewEligible','reviewCount','nextReview','lastReviewedAt','lastReviewQuality','reviewIntervalDays','reviewEaseFactor','isInLearnList']
          else null end;
        if v_allowed is null then return false; end if;
      end if;
      for v_key, v_nested in select key, value from jsonb_each(p_value)
      loop
        v_normalized_key := lower(regexp_replace(v_key, '([a-z0-9])([A-Z])', '\1_\2', 'g'));
        if v_normalized_key ~ '(^|_)(bytes?|blob|binary|base64|data|content|body)($|_)' then
          return false;
        end if;
        if v_allowed is not null and v_key <> all(v_allowed) then return false; end if;
        if not public.sync_v2_json_is_bounded(v_nested, p_depth + 1, v_key) then
          return false;
        end if;
      end loop;
      return true;
    else return false;
  end case;
end;
$$;

insert into public.service_schema_versions (component, migration_version)
values ('account_sync', '20260902153000')
on conflict (component) do update
set migration_version = excluded.migration_version,
    updated_at = now();

commit;
