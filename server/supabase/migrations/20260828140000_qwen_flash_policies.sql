-- Desk and production Worker default to qwen3.7-flash. Seeded policies used
-- qwen3.7-plus and silently overrode Desk on every managed Qwen call.
update public.model_policies
set
  model = 'qwen3.7-flash',
  updated_at = now()
where model = 'qwen3.7-plus';
