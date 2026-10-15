-- Vinyl Hustler: database su Supabase (Postgres).
-- Si esegue una volta: Supabase > SQL Editor > incolla > Run (oppure: supabase db push).
-- I dischi e le foto restano sul telefono; qui stanno solo account, piano e consumi (per gli abbonamenti).

create table if not exists public.profiles (
    id uuid primary key references auth.users (id) on delete cascade,
    discogs_username text,
    plan text not null default 'start',          -- start / pro / shop (proposta C)
    ai_monthly_cap_eur numeric not null default 3, -- tetto di spesa AI al mese per utente
    created_at timestamptz not null default now()
);

create table if not exists public.usage_monthly (
    user_id uuid not null references auth.users (id) on delete cascade,
    month date not null,                          -- primo giorno del mese
    discs integer not null default 0,
    ai_calls integer not null default 0,
    ai_cost_eur numeric not null default 0,
    primary key (user_id, month)
);

create table if not exists public.ai_calls (
    id bigint generated always as identity primary key,
    user_id uuid not null references auth.users (id) on delete cascade,
    task text not null,                           -- match / read
    model text not null,
    input_tokens integer,
    output_tokens integer,
    cost_eur numeric,
    created_at timestamptz not null default now()
);

-- Profilo creato in automatico alla prima registrazione.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
    insert into public.profiles (id) values (new.id) on conflict do nothing;
    return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
    for each row execute function public.handle_new_user();

-- Somma atomica dei consumi (la chiama la funzione ai-cover con la chiave di servizio).
create or replace function public.add_ai_usage(p_user uuid, p_cost numeric) returns void
language sql security definer set search_path = public as $$
    insert into public.usage_monthly (user_id, month, ai_calls, ai_cost_eur)
    values (p_user, date_trunc('month', now())::date, 1, p_cost)
    on conflict (user_id, month) do update
        set ai_calls = usage_monthly.ai_calls + 1,
            ai_cost_eur = usage_monthly.ai_cost_eur + excluded.ai_cost_eur;
$$;

-- Sicurezza: ogni utente vede solo i suoi dati; le scritture le fa solo il server.
alter table public.profiles enable row level security;
alter table public.usage_monthly enable row level security;
alter table public.ai_calls enable row level security;

create policy "profilo: lettura propria" on public.profiles for select using ((select auth.uid()) = id);
create policy "consumi: lettura propria" on public.usage_monthly for select using ((select auth.uid()) = user_id);
create policy "chiamate AI: lettura propria" on public.ai_calls for select using ((select auth.uid()) = user_id);

revoke execute on function public.add_ai_usage(uuid, numeric) from public, anon, authenticated;

revoke execute on function public.handle_new_user() from public, anon, authenticated;
