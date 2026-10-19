-- V56: correzioni del controllo di sicurezza R1 (SEC-002, SEC-003, SEC-006).

-- SEC-002 · Tetti AI e voce: il budget si PRENOTA prima di chiamare Anthropic / ElevenLabs, in un solo passo.
-- L'update blocca la riga: richieste partite insieme passano una alla volta e quella che sfora viene rifiutata.
create or replace function public.reserve_ai(p_user uuid, p_cost numeric, p_cap numeric) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  insert into usage_monthly (user_id, month) values (p_user, date_trunc('month', now())::date)
  on conflict (user_id, month) do nothing;
  update usage_monthly set ai_cost_eur = ai_cost_eur + p_cost
   where user_id = p_user and month = date_trunc('month', now())::date and ai_cost_eur + p_cost <= p_cap;
  return found;
end $$;

-- Correzione dopo la chiamata: costo vero meno prenotazione (anche negativo = restituisce).
create or replace function public.adjust_ai(p_user uuid, p_delta numeric, p_call boolean) returns void
language sql security definer set search_path = public as $$
  update usage_monthly set ai_cost_eur = greatest(0, ai_cost_eur + p_delta),
                           ai_calls = ai_calls + (case when p_call then 1 else 0 end)
   where user_id = p_user and month = date_trunc('month', now())::date;
$$;

create or replace function public.reserve_voice(p_user uuid, p_chars integer, p_cap integer) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  insert into usage_monthly (user_id, month) values (p_user, date_trunc('month', now())::date)
  on conflict (user_id, month) do nothing;
  update usage_monthly set voice_chars = voice_chars + p_chars
   where user_id = p_user and month = date_trunc('month', now())::date and voice_chars + p_chars <= p_cap;
  return found;
end $$;

revoke execute on function public.reserve_ai(uuid, numeric, numeric) from public, anon, authenticated;
revoke execute on function public.adjust_ai(uuid, numeric, boolean) from public, anon, authenticated;
revoke execute on function public.reserve_voice(uuid, integer, integer) from public, anon, authenticated;

-- SEC-003 · Memoria condivisa.
-- 1. Titolo e copertina non si sovrascrivono più: resta il primo valore (che ora calcola il server da Discogs).
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
    set title = coalesce(disc_memory.title, excluded.title),
        cover_url = coalesce(disc_memory.cover_url, excluded.cover_url)
  returning id into mid;
  insert into disc_memory_votes (memory_id, user_id) values (mid, p_user) on conflict do nothing;
  get diagnostics n = row_count;
  if n > 0 then
    update disc_memory set confirmations = confirmations + 1, updated_at = now() where id = mid;
  end if;
end $$;
revoke all on function public.learn_disc(uuid, text, text, bigint, integer, text, text) from public, anon, authenticated;

-- 2. Agli altri si propone un abbinamento solo se l'hanno confermato almeno 2 persone diverse;
--    chi l'ha insegnato lo ritrova sempre.
create or replace function public.lookup_dhash_safe(p_dhash bigint, p_max integer, p_user uuid, p_min integer)
returns table (release_id integer, title text, cover_url text, confirmations integer, dist integer)
language sql stable set search_path = public as $$
  select m.release_id, m.title, m.cover_url, m.confirmations, bit_count((m.dhash # p_dhash)::bit(64))::int as dist
  from disc_memory m
  where m.kind = 'dhash' and bit_count((m.dhash # p_dhash)::bit(64)) <= p_max
    and (m.confirmations >= p_min
         or exists (select 1 from disc_memory_votes v where v.memory_id = m.id and v.user_id = p_user))
  order by dist, m.confirmations desc
  limit 1;
$$;

create or replace function public.lookup_reads_safe(p_keys text[], p_user uuid, p_min integer)
returns table (key text, release_id integer, title text, cover_url text, confirmations integer)
language sql stable set search_path = public as $$
  select distinct on (m.key) m.key, m.release_id, m.title, m.cover_url, m.confirmations
  from disc_memory m
  where m.kind = 'read' and m.key = any (p_keys)
    and (m.confirmations >= p_min
         or exists (select 1 from disc_memory_votes v where v.memory_id = m.id and v.user_id = p_user))
  order by m.key, m.confirmations desc;
$$;
revoke all on function public.lookup_dhash_safe(bigint, integer, uuid, integer) from public, anon, authenticated;
revoke all on function public.lookup_reads_safe(text[], uuid, integer) from public, anon, authenticated;

-- 3. Copertine già salvate che non vengono da Discogs: via.
update public.disc_memory set cover_url = null
 where cover_url is not null and cover_url !~ '^https://(i|img|st)\.discogs\.com/';

-- SEC-006 · Permessi minimi: l'app legge solo i propri dati (RLS); tutte le scritture le fa il server.
revoke insert, update, delete, truncate, references, trigger on all tables in schema public from anon, authenticated;
revoke select on all tables in schema public from anon;
