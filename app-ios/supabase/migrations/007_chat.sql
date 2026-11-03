-- V68 · CHAT tra gli utenti di Vinyl Hustler (applicata su Supabase il 27 ott 2026 come «chat_v1»)
-- Copia d'archivio: è già sul database. I permessi sono stati poi stretti dalla 008.
create unique index if not exists profiles_discogs_unico on public.profiles (lower(discogs_username)) where discogs_username is not null;

create table if not exists public.chat_contatti (
  proprietario uuid not null references auth.users(id) on delete cascade,
  contatto uuid not null references auth.users(id) on delete cascade,
  creato timestamptz not null default now(),
  primary key (proprietario, contatto),
  check (proprietario <> contatto)
);
create index if not exists chat_contatti_contatto on public.chat_contatti (contatto);

create table if not exists public.chat_blocchi (
  chi uuid not null references auth.users(id) on delete cascade,
  bloccato uuid not null references auth.users(id) on delete cascade,
  creato timestamptz not null default now(),
  primary key (chi, bloccato),
  check (chi <> bloccato)
);
create index if not exists chat_blocchi_bloccato on public.chat_blocchi (bloccato);

create table if not exists public.chat_messaggi (
  id bigint generated always as identity primary key,
  da uuid not null default auth.uid() references auth.users(id) on delete cascade,
  a uuid not null references auth.users(id) on delete cascade,
  testo text check (char_length(testo) <= 2000),
  disco jsonb,
  tipo text check (tipo in ('proposta', 'parere')),
  risposta text check (risposta in ('Alza', 'Giusto', 'Abbassa', 'Mi interessa')),
  creato timestamptz not null default now(),
  letto timestamptz,
  check (da <> a),
  check (testo is not null or disco is not null)
);
create index if not exists chat_messaggi_a on public.chat_messaggi (a, creato desc);
create index if not exists chat_messaggi_da on public.chat_messaggi (da, creato desc);

create table if not exists public.chat_segnalazioni (
  id bigint generated always as identity primary key,
  chi uuid not null default auth.uid() references auth.users(id) on delete cascade,
  segnalato uuid not null references auth.users(id) on delete cascade,
  messaggio bigint references public.chat_messaggi(id) on delete set null,
  motivo text check (char_length(motivo) <= 500),
  creato timestamptz not null default now()
);
create index if not exists chat_segnalazioni_chi on public.chat_segnalazioni (chi);
create index if not exists chat_segnalazioni_segnalato on public.chat_segnalazioni (segnalato);
create index if not exists chat_segnalazioni_messaggio on public.chat_segnalazioni (messaggio);

alter table public.chat_contatti enable row level security;
alter table public.chat_blocchi enable row level security;
alter table public.chat_messaggi enable row level security;
alter table public.chat_segnalazioni enable row level security;

create policy "contatti: i miei" on public.chat_contatti for select to authenticated using ((select auth.uid()) = proprietario);
create policy "contatti: aggiungo" on public.chat_contatti for insert to authenticated with check ((select auth.uid()) = proprietario);
create policy "contatti: tolgo" on public.chat_contatti for delete to authenticated using ((select auth.uid()) = proprietario);

create policy "blocchi: i miei" on public.chat_blocchi for select to authenticated using ((select auth.uid()) = chi);
create policy "blocchi: blocco" on public.chat_blocchi for insert to authenticated with check ((select auth.uid()) = chi);
create policy "blocchi: sblocco" on public.chat_blocchi for delete to authenticated using ((select auth.uid()) = chi);

create policy "messaggi: i miei" on public.chat_messaggi for select to authenticated
  using ((select auth.uid()) = da or (select auth.uid()) = a);
create policy "messaggi: scrivo" on public.chat_messaggi for insert to authenticated
  with check (
    (select auth.uid()) = da
    and risposta is null and letto is null
    and not exists (select 1 from public.chat_blocchi b where b.chi = a and b.bloccato = (select auth.uid()))
  );

create policy "segnalazioni: invio" on public.chat_segnalazioni for insert to authenticated with check ((select auth.uid()) = chi);

create or replace function public.chat_pulisci() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.testo is not null then
    new.testo := regexp_replace(new.testo,
      '\m(stronz[oaie]|cazz[oi]|vaffanculo|coglion[ei]|merd[ae]|idiot[ai]|puttan[ae]|bastard[oi]|fuck|shit|bitch|asshole)\M',
      '•••', 'gi');
  end if;
  return new;
end $$;
drop trigger if exists chat_pulisci on public.chat_messaggi;
create trigger chat_pulisci before insert on public.chat_messaggi for each row execute function public.chat_pulisci();

create or replace function public.chat_cerca(q text) returns table (id uuid, nome text) language sql stable security definer set search_path = '' as $$
  select p.id, p.discogs_username
  from public.profiles p
  where p.discogs_username is not null
    and length(btrim(q)) >= 2
    and p.discogs_username ilike '%' || replace(replace(btrim(q), '%', ''), '_', '\_') || '%'
    and p.id <> (select auth.uid())
    and not exists (select 1 from public.chat_blocchi b where b.chi = p.id and b.bloccato = (select auth.uid()))
  order by (lower(p.discogs_username) = lower(btrim(q))) desc, p.discogs_username
  limit 20
$$;

create or replace function public.chat_nomi(ids uuid[]) returns table (id uuid, nome text) language sql stable security definer set search_path = '' as $$
  select p.id, p.discogs_username from public.profiles p
  where p.id = any(ids) and (select auth.uid()) is not null
$$;

create or replace function public.chat_letti(chi uuid) returns void language sql security definer set search_path = '' as $$
  update public.chat_messaggi set letto = now()
  where a = (select auth.uid()) and da = chi and letto is null
$$;

create or replace function public.chat_rispondi(messaggio bigint, valore text) returns void language sql security definer set search_path = '' as $$
  update public.chat_messaggi set risposta = valore
  where id = messaggio and a = (select auth.uid()) and disco is not null and risposta is null
$$;
-- (chat_registra: vedi la versione aggiornata nella 008)

revoke execute on function public.chat_cerca(text), public.chat_nomi(uuid[]), public.chat_letti(uuid), public.chat_rispondi(bigint, text) from public, anon;
grant execute on function public.chat_cerca(text), public.chat_nomi(uuid[]), public.chat_letti(uuid), public.chat_rispondi(bigint, text) to authenticated;
revoke execute on function public.chat_pulisci() from public, anon, authenticated;
