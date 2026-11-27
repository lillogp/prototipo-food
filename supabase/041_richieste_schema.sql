-- Richieste di ritiro (fase 1): schema, tipo account "commerciante", chiusure straordinarie, configurazione.
-- Già applicata su Supabase.

alter table public.profiles drop constraint if exists profiles_account_type_check;
alter table public.profiles add constraint profiles_account_type_check check (account_type = any (array['user','pro','commerciante']));

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check check (type = any (array[
  'follow','follow_request','follow_accepted','like','comment','comment_like','client_joined','plan','message','dm','dm_request',
  'story_like','admin_warning','secret_request','secret_accepted','tag',
  'richiesta_nuova','richiesta_confermata','richiesta_rifiutata','richiesta_proposta','richiesta_scaduta','richiesta_annullata']));

alter table public.botteghe add column if not exists chiusure jsonb not null default '[]'::jsonb;
grant update (chiusure) on public.botteghe to authenticated;

create table if not exists private.richieste_config (key text primary key, value int not null);
insert into private.richieste_config (key, value) values ('scadenza_min', 30), ('max_aperte', 6), ('max_giorni', 14) on conflict (key) do nothing;
create or replace function private.richiesta_config(k text) returns int language sql stable security definer set search_path = '' as $$
  select value from private.richieste_config where key = k
$$;

create table public.richieste_ritiro (
  id uuid primary key default gen_random_uuid(),
  bottega_id bigint not null references public.botteghe(id) on delete cascade,
  cliente_id uuid not null references public.profiles(id) on delete cascade,
  stato text not null default 'inviata' check (stato = any (array['inviata','vista','confermata','rifiutata','proposta','scaduta','annullata','ritirata','non_presentato'])),
  ritiro_at timestamptz not null,
  ritiro_proposto_at timestamptz,
  nota_cliente text check (nota_cliente is null or char_length(nota_cliente) <= 300),
  motivo_rifiuto text check (motivo_rifiuto is null or char_length(motivo_rifiuto) <= 200),
  scade_at timestamptz,
  visto_at timestamptz,
  risposto_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index richieste_bottega_idx on public.richieste_ritiro (bottega_id, stato, ritiro_at);
create index richieste_cliente_idx on public.richieste_ritiro (cliente_id, stato);
create index richieste_scadenza_idx on public.richieste_ritiro (scade_at) where stato in ('inviata','vista','proposta');

create table public.richiesta_righe (
  id bigint generated always as identity primary key,
  richiesta_id uuid not null references public.richieste_ritiro(id) on delete cascade,
  prodotto_id bigint references public.prodotti(id) on delete set null,
  nome text not null,
  unita text,
  prezzo_cent int not null,
  quantita numeric not null check (quantita > 0)
);
create index richiesta_righe_idx on public.richiesta_righe (richiesta_id);

alter table public.richieste_ritiro enable row level security;
alter table public.richiesta_righe enable row level security;
revoke all on public.richieste_ritiro, public.richiesta_righe from anon, authenticated;
grant select on public.richieste_ritiro, public.richiesta_righe to authenticated;

create policy "richieste: cliente, titolare o admin" on public.richieste_ritiro for select to authenticated using (
  cliente_id = (select auth.uid())
  or exists (select 1 from public.botteghe b where b.id = bottega_id and b.owner_id = (select auth.uid()))
  or private.is_admin());
create policy "righe: come la richiesta" on public.richiesta_righe for select to authenticated using (
  exists (select 1 from public.richieste_ritiro r where r.id = richiesta_id));
