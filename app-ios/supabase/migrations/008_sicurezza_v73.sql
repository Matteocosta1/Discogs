-- V73 · controllo con le skill Supabase (applicata su Supabase il 3 nov 2026 come «sicurezza_v73»)

-- 1 · Chat: solo i permessi che l'app usa davvero (chi non ha fatto l'accesso: niente)
revoke all on table public.chat_contatti, public.chat_blocchi, public.chat_messaggi, public.chat_segnalazioni from anon, authenticated;
grant select, insert, delete on table public.chat_contatti to authenticated;
grant select, insert, delete on table public.chat_blocchi to authenticated;
grant select, insert on table public.chat_messaggi to authenticated;
grant insert on table public.chat_segnalazioni to authenticated;
revoke all on sequence public.chat_messaggi_id_seq, public.chat_segnalazioni_id_seq from anon, authenticated;

-- 2 · Tabelle, funzioni e sequenze NUOVE: nessun permesso automatico (si danno a mano, una per una)
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated, service_role;
alter default privileges for role postgres in schema public revoke execute on functions from anon, authenticated, service_role;
alter default privileges for role postgres in schema public revoke execute on functions from public;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated, service_role;

-- 5a · Nome Discogs registrato nello stesso istante da due persone: «occupato», non un errore generico
create or replace function public.chat_registra(nome text) returns text language plpgsql security definer set search_path = '' as $$
declare n text := btrim(nome);
begin
  if (select auth.uid()) is null then raise exception 'non autenticato'; end if;
  if n is null or n = '' then return null; end if;
  if exists (select 1 from public.profiles p where lower(p.discogs_username) = lower(n) and p.id <> (select auth.uid())) then
    return 'occupato';
  end if;
  update public.profiles set discogs_username = n where id = (select auth.uid());
  return 'ok';
exception when unique_violation then
  return 'occupato';
end $$;
revoke execute on function public.chat_registra(text) from public, anon;
grant execute on function public.chat_registra(text) to authenticated;

-- 5b · Le regole di lettura valgono solo per chi ha fatto l'accesso
alter policy "profilo: lettura propria" on public.profiles to authenticated;
alter policy "consumi: lettura propria" on public.usage_monthly to authenticated;
alter policy "chiamate AI: lettura propria" on public.ai_calls to authenticated;

-- 5c · I messaggi non passano dal «tempo reale» (l'app li rilegge): niente lavoro inutile sul server
alter publication supabase_realtime drop table public.chat_messaggi;
