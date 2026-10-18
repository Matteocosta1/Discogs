-- V35: sicurezza.
-- 1. Amministratori: solo loro cambiano la pronuncia condivisa.
alter table public.profiles add column if not exists is_admin boolean not null default false;
-- (gli amministratori si segnano a mano: update profiles set is_admin = true where id = '...')

-- 2. Tetto della voce: caratteri nuovi generati con ElevenLabs al mese (le frasi già in memoria non contano).
alter table public.profiles add column if not exists voice_monthly_chars integer not null default 20000;
alter table public.usage_monthly add column if not exists voice_chars integer not null default 0;

create or replace function public.add_voice_usage(p_user uuid, p_chars integer) returns void
language sql security definer set search_path = public as $$
    insert into public.usage_monthly (user_id, month, voice_chars)
    values (p_user, date_trunc('month', now())::date, p_chars)
    on conflict (user_id, month) do update
        set voice_chars = usage_monthly.voice_chars + excluded.voice_chars;
$$;
revoke execute on function public.add_voice_usage(uuid, integer) from public, anon, authenticated;

-- 3. Memoria condivisa: una conferma conta una volta per persona (niente voti ripetuti).
create table if not exists public.disc_memory_votes (
  memory_id bigint not null references public.disc_memory (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (memory_id, user_id)
);
alter table public.disc_memory_votes enable row level security;
create index if not exists disc_memory_votes_user on public.disc_memory_votes (user_id);

-- (la versione vecchia di learn_disc a 6 parametri resta, chiusa: non la chiama più nessuno)
create or replace function public.learn_disc(p_user uuid, p_kind text, p_key text, p_dhash bigint, p_release integer,
                                             p_title text, p_cover text)
returns void language plpgsql set search_path = public as $$
declare
  mid bigint;
  n integer;
begin
  insert into disc_memory (kind, key, dhash, release_id, title, cover_url, confirmations)
  values (p_kind, p_key, p_dhash, p_release, p_title, p_cover, 0)
  on conflict (kind, key, release_id) do update
    set title = coalesce(excluded.title, disc_memory.title),
        cover_url = coalesce(excluded.cover_url, disc_memory.cover_url)
  returning id into mid;
  insert into disc_memory_votes (memory_id, user_id) values (mid, p_user) on conflict do nothing;
  get diagnostics n = row_count;
  if n > 0 then
    update disc_memory set confirmations = confirmations + 1, updated_at = now() where id = mid;
  end if;
end $$;
revoke all on function public.learn_disc(uuid, text, text, bigint, integer, text, text) from public, anon, authenticated;

-- 4. Funzione di sistema: non chiamabile dall'esterno.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

-- indice consigliato
create index if not exists ai_compare_user on public.ai_compare (user_id);
