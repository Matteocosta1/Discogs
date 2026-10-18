-- Pronuncia: come dire una parola (nomi di artisti, titoli stranieri). Vale per tutti gli utenti.
create table if not exists public.voice_lexicon (
  word text primary key,           -- in minuscolo, com'è scritta ("miles davis")
  say_as text not null,            -- come va detta ("Màils Dèivis")
  updated_by uuid,
  updated_at timestamptz not null default now()
);
alter table public.voice_lexicon enable row level security;

-- Le frasi già generate, per tutti: si salvano una volta e poi si riusano gratis.
insert into storage.buckets (id, name, public)
values ('voce', 'voce', false)
on conflict (id) do nothing;
