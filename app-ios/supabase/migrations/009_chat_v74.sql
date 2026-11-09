-- V74 · Chat: nome in Chat (due telefoni sullo stesso account Discogs), foto private (30 giorni),
-- schede «Annuncio», sincronizzazione delle modifiche (risposte e «letto») in pochi secondi.

-- 1. Nome in Chat: «Nome · account Discogs». Unico per coppia (nome, account), non più per account.
alter table public.profiles add column if not exists nome_chat text;
alter table public.profiles drop constraint if exists profiles_nome_chat_check;
alter table public.profiles add constraint profiles_nome_chat_check check (nome_chat is null or char_length(nome_chat) between 2 and 24);
drop index if exists public.profiles_discogs_unico;
create unique index if not exists profiles_chat_unico on public.profiles (lower(discogs_username), lower(nome_chat))
  where discogs_username is not null and nome_chat is not null;

create or replace function public.chat_registra(nome text, discogs text)
returns text language plpgsql security definer set search_path = '' as $$
declare n text := left(btrim(coalesce(nome, '')), 24); d text := btrim(coalesce(discogs, ''));
begin
  if (select auth.uid()) is null then raise exception 'non autenticato'; end if;
  if d = '' then return null; end if;
  if char_length(n) < 2 then n := null; end if;
  if n is not null and exists (select 1 from public.profiles p
      where lower(p.discogs_username) = lower(d) and lower(p.nome_chat) = lower(n) and p.id <> (select auth.uid())) then
    return 'occupato';
  end if;
  update public.profiles set discogs_username = d, nome_chat = n where id = (select auth.uid());
  return 'ok';
exception when unique_violation then
  return 'occupato';
end $$;
revoke all on function public.chat_registra(text, text) from public, anon;
grant execute on function public.chat_registra(text, text) to authenticated;

-- il nome che vedono gli altri
create or replace function public.chat_nome_di(p public.profiles)
returns text language sql immutable set search_path = '' as $$
  select case when p.nome_chat is not null then p.nome_chat || ' · ' || p.discogs_username else p.discogs_username end
$$;
revoke all on function public.chat_nome_di(public.profiles) from public, anon;
grant execute on function public.chat_nome_di(public.profiles) to authenticated;

create or replace function public.chat_cerca(q text)
returns table(id uuid, nome text) language sql stable security definer set search_path = '' as $$
  select p.id, public.chat_nome_di(p)
  from public.profiles p
  where p.discogs_username is not null
    and length(btrim(q)) >= 2
    and (p.discogs_username ilike '%' || replace(replace(btrim(q), '%', ''), '_', '\_') || '%'
         or p.nome_chat ilike '%' || replace(replace(btrim(q), '%', ''), '_', '\_') || '%')
    and p.id <> (select auth.uid())
    and not exists (select 1 from public.chat_blocchi b where b.chi = p.id and b.bloccato = (select auth.uid()))
  order by (lower(p.discogs_username) = lower(btrim(q))) desc, p.discogs_username, p.nome_chat
  limit 20
$$;

create or replace function public.chat_nomi(ids uuid[])
returns table(id uuid, nome text) language sql stable security definer set search_path = '' as $$
  select p.id, public.chat_nome_di(p) from public.profiles p
  where p.id = any(ids) and (select auth.uid()) is not null
$$;

-- 2. Messaggi: foto, «Annuncio», ora dell'ultima modifica
alter table public.chat_messaggi add column if not exists foto text;
alter table public.chat_messaggi add column if not exists aggiornato timestamptz not null default now();
alter table public.chat_messaggi drop constraint if exists chat_messaggi_check1;
alter table public.chat_messaggi drop constraint if exists chat_messaggi_contenuto_check;
alter table public.chat_messaggi add constraint chat_messaggi_contenuto_check check (testo is not null or disco is not null or foto is not null);
alter table public.chat_messaggi drop constraint if exists chat_messaggi_tipo_check;
alter table public.chat_messaggi add constraint chat_messaggi_tipo_check check (tipo = any (array['proposta', 'parere', 'annuncio']));
alter table public.chat_messaggi drop constraint if exists chat_messaggi_foto_check;
alter table public.chat_messaggi add constraint chat_messaggi_foto_check check (
  foto is null or (foto ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}\.jpg$'
                   and split_part(foto, '/', 1) = da::text and split_part(foto, '/', 2) = a::text));

-- l'ora di creazione e di modifica le mette sempre il server
create or replace function public.chat_ora()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then new.creato := now(); end if;
  new.aggiornato := clock_timestamp();
  return new;
end $$;
revoke all on function public.chat_ora() from public, anon, authenticated;
drop trigger if exists chat_ora on public.chat_messaggi;
create trigger chat_ora before insert or update on public.chat_messaggi for each row execute function public.chat_ora();
create index if not exists chat_messaggi_a_agg on public.chat_messaggi (a, aggiornato);
create index if not exists chat_messaggi_da_agg on public.chat_messaggi (da, aggiornato);

-- 3. Foto: spazio privato «chat-foto». Percorso <chi manda>/<chi riceve>/<id>.jpg; le vedono solo i due
--    della conversazione e solo per 30 giorni (poi le cancella la pulizia notturna).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-foto', 'chat-foto', false, 5242880, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg'];

drop policy if exists "chat foto: carico le mie" on storage.objects;
create policy "chat foto: carico le mie" on storage.objects for insert to authenticated
with check (
  bucket_id = 'chat-foto'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and not exists (select 1 from public.chat_blocchi b
                  where b.chi::text = (storage.foldername(name))[2] and b.bloccato = (select auth.uid()))
);
drop policy if exists "chat foto: le vedono i due della chat" on storage.objects;
create policy "chat foto: le vedono i due della chat" on storage.objects for select to authenticated
using (
  bucket_id = 'chat-foto'
  and (select auth.uid())::text in ((storage.foldername(name))[1], (storage.foldername(name))[2])
  and created_at > now() - interval '30 days'
);

-- 4. Pulizia notturna delle foto con più di 30 giorni (funzione chat-pulizia, chiamata da pg_cron)
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

create or replace function public.chat_foto_scadute()
returns setof text language sql stable security definer set search_path = '' as $$
  select o.name from storage.objects o
  where o.bucket_id = 'chat-foto' and o.created_at < now() - interval '30 days'
  order by o.created_at limit 1000
$$;
revoke all on function public.chat_foto_scadute() from public, anon, authenticated;
grant execute on function public.chat_foto_scadute() to service_role;

-- la chiave della pulizia resta nel vault: la funzione la confronta qui, senza mai uscire dal database
do $$ begin
  if not exists (select 1 from vault.secrets where name = 'chat_pulizia_chiave') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'chat_pulizia_chiave', 'Chiave della pulizia delle foto della chat');
  end if;
end $$;
create or replace function public.chat_pulizia_ok(k text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from vault.decrypted_secrets s where s.name = 'chat_pulizia_chiave' and s.decrypted_secret = k)
$$;
revoke all on function public.chat_pulizia_ok(text) from public, anon, authenticated;
grant execute on function public.chat_pulizia_ok(text) to service_role;

do $$ begin
  perform cron.unschedule('chat-pulizia-foto') where exists (select 1 from cron.job where jobname = 'chat-pulizia-foto');
end $$;
select cron.schedule('chat-pulizia-foto', '17 3 * * *', $c$
  select net.http_post(
    url := 'https://ysgvukkcqwzzreutgwqh.supabase.co/functions/v1/chat-pulizia',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-chiave', (select decrypted_secret from vault.decrypted_secrets where name = 'chat_pulizia_chiave')),
    body := '{}'::jsonb)
$c$);
