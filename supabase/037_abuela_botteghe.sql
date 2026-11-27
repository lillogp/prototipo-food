-- 037 · Abuela Frog: botteghe dei commercianti e prodotti (ANTEPRIMA).
-- Già applicato al database "Gusto". Lo vedono solo i profili con can_abuela = true (e il proprietario della bottega / gli admin).
-- Per aprirlo a tutti: update public.profiles set can_abuela = true;  (oppure cambiare la policy "botteghe visibili in anteprima").

alter table public.profiles add column if not exists can_abuela boolean not null default false;

create or replace function private.guard_can_abuela()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.can_abuela is distinct from old.can_abuela and coalesce(auth.role(), '') in ('authenticated','anon') then
    new.can_abuela := old.can_abuela;
  end if;
  return new;
end $$;
drop trigger if exists guard_can_abuela on public.profiles;
create trigger guard_can_abuela before update on public.profiles
  for each row execute function private.guard_can_abuela();

create or replace function private.can_abuela()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select can_abuela from public.profiles where id = auth.uid()), false)
$$;
revoke all on function private.can_abuela() from public, anon;
grant execute on function private.can_abuela() to authenticated;

create table public.botteghe (
  id bigint generated always as identity primary key,
  owner_id uuid not null unique references public.profiles(id) on delete cascade,
  nome text not null check (char_length(nome) between 2 and 80),
  categoria text not null check (categoria in ('formaggi','macelleria','pescheria','ortofrutta','forno','uova','vino','dispensa')),
  zona text not null default '' check (char_length(zona) <= 80),
  descr text not null default '' check (char_length(descr) <= 300),
  ritiro boolean not null default true,
  spedizione boolean not null default false,
  orari text not null default '' check (char_length(orari) <= 120),
  attiva boolean not null default true,
  created_at timestamptz not null default now(),
  indirizzo text not null default '' check (char_length(indirizzo) <= 160),
  telefono text not null default '' check (char_length(telefono) <= 30),
  spedizione_info text not null default '' check (char_length(spedizione_info) <= 200)
);

create table public.prodotti (
  id bigint generated always as identity primary key,
  bottega_id bigint not null references public.botteghe(id) on delete cascade,
  nome text not null check (char_length(nome) between 2 and 80),
  prezzo_cent integer not null check (prezzo_cent >= 0 and prezzo_cent < 10000000),
  unita text not null default '' check (char_length(unita) <= 30),
  disponibile boolean not null default true,
  pos integer not null default 0,
  created_at timestamptz not null default now()
);
create index prodotti_bottega_idx on public.prodotti(bottega_id);

alter table public.botteghe enable row level security;
alter table public.prodotti enable row level security;

create policy "botteghe visibili in anteprima" on public.botteghe for select to authenticated
  using (private.can_abuela() or owner_id = (select auth.uid()) or private.is_admin());
create policy "botteghe create solo admin" on public.botteghe for insert to authenticated
  with check (private.is_admin());
create policy "bottega modifica proprietario o admin" on public.botteghe for update to authenticated
  using (owner_id = (select auth.uid()) or private.is_admin())
  with check (owner_id = (select auth.uid()) or private.is_admin());
create policy "botteghe elimina solo admin" on public.botteghe for delete to authenticated
  using (private.is_admin());

create policy "prodotti visibili in anteprima" on public.prodotti for select to authenticated
  using (exists (select 1 from public.botteghe b where b.id = bottega_id
    and (private.can_abuela() or b.owner_id = (select auth.uid()) or private.is_admin())));
create policy "prodotti gestiti da proprietario o admin" on public.prodotti for all to authenticated
  using (exists (select 1 from public.botteghe b where b.id = bottega_id and (b.owner_id = (select auth.uid()) or private.is_admin())))
  with check (exists (select 1 from public.botteghe b where b.id = bottega_id and (b.owner_id = (select auth.uid()) or private.is_admin())));

revoke all on public.botteghe, public.prodotti from anon, authenticated;
grant select, insert, delete on public.botteghe to authenticated;
grant update (nome, categoria, zona, descr, ritiro, spedizione, orari, indirizzo, telefono, spedizione_info, attiva) on public.botteghe to authenticated;
grant select, insert, update, delete on public.prodotti to authenticated;

-- Solo un admin può attivare/disattivare una bottega o cambiarne il proprietario.
create or replace function private.guard_botteghe()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(auth.role(), '') in ('authenticated','anon') and not private.is_admin() then
    new.attiva := old.attiva;
    new.owner_id := old.owner_id;
  end if;
  return new;
end $$;
create trigger guard_botteghe before update on public.botteghe
  for each row execute function private.guard_botteghe();

-- Massimo 300 prodotti per bottega.
create or replace function private.limite_prodotti()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if (select count(*) from public.prodotti where bottega_id = new.bottega_id) >= 300 then
    raise exception 'Troppi prodotti in questa bottega (massimo 300)';
  end if;
  return new;
end $$;
create trigger limite_prodotti before insert on public.prodotti
  for each row execute function private.limite_prodotti();
