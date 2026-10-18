-- Memoria condivisa dei dischi: ogni conferma di un utente insegna all'app.
-- Solo testo, niente foto. La legge e la scrive solo la funzione "memoria" (service role): RLS senza policy.
create table if not exists public.disc_memory (
  id bigserial primary key,
  kind text not null check (kind in ('read', 'dhash')),   -- read = cosa ha letto l'AI; dhash = impronta della foto
  key text not null,                                      -- testo normalizzato, o l'impronta in esadecimale
  dhash bigint,                                           -- impronta numerica (solo kind = 'dhash')
  release_id integer not null,
  title text,
  cover_url text,
  confirmations integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (kind, key, release_id)
);
alter table public.disc_memory enable row level security;
create index if not exists disc_memory_read on public.disc_memory (kind, key);

-- Una conferma: se la coppia (chiave, release) c'è già, +1.
create or replace function public.learn_disc(p_kind text, p_key text, p_dhash bigint, p_release integer,
                                             p_title text, p_cover text)
returns void language sql set search_path = public as $$
  insert into disc_memory (kind, key, dhash, release_id, title, cover_url)
  values (p_kind, p_key, p_dhash, p_release, p_title, p_cover)
  on conflict (kind, key, release_id) do update
    set confirmations = disc_memory.confirmations + 1,
        title = coalesce(excluded.title, disc_memory.title),
        cover_url = coalesce(excluded.cover_url, disc_memory.cover_url),
        updated_at = now();
$$;

-- L'impronta più vicina (al massimo p_max bit diversi su 64), la più confermata a parità.
create or replace function public.lookup_dhash(p_dhash bigint, p_max integer)
returns table (release_id integer, title text, cover_url text, confirmations integer, dist integer)
language sql stable set search_path = public as $$
  select release_id, title, cover_url, confirmations, bit_count((dhash # p_dhash)::bit(64))::int as dist
  from disc_memory
  where kind = 'dhash' and bit_count((dhash # p_dhash)::bit(64)) <= p_max
  order by dist, confirmations desc
  limit 1;
$$;

revoke all on function public.learn_disc(text, text, bigint, integer, text, text) from public, anon, authenticated;
revoke all on function public.lookup_dhash(bigint, integer) from public, anon, authenticated;
