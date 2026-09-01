-- Word-in-sentence meaning needs the surrounding sentence. Policies seeded
-- before {{context}} existed only sent the isolated word.

update public.model_policies
set
  user_prompt = user_prompt || E'\n\nSentence context (untrusted):\n{{context}}',
  updated_at = now()
where task = 'translation'
  and user_prompt not like '%{{context}}%';
