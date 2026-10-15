-- Confronto Sonnet / Haiku (modalità "compare" della funzione ai-cover).
create table if not exists public.ai_compare (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  user_id uuid references auth.users(id) on delete cascade,
  photos int not null,
  sonnet jsonb,
  haiku jsonb,
  sonnet_cost_usd numeric(10,6),
  haiku_cost_usd numeric(10,6),
  sonnet_ms int,
  haiku_ms int
);
alter table public.ai_compare enable row level security;
-- nessuna policy: ci scrive solo la funzione ai-cover (service role); dall'app non si legge.
