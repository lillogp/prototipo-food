-- Gusto: schema iniziale. Tutte le tabelle hanno RLS attiva.

-- Profili ---------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  handle text unique,
  display_name text not null default '',
  account_type text not null default 'user' check (account_type in ('user','pro')),
  pro_verified boolean not null default false,   -- lo imposta solo l'amministratore
  pro_title text,
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
create policy "profili visibili agli utenti" on public.profiles for select to authenticated using (true);
create policy "ognuno modifica il proprio profilo" on public.profiles for update to authenticated
  using ((select auth.uid()) = id) with check ((select auth.uid()) = id);
revoke update on public.profiles from authenticated;
grant update (handle, display_name, pro_title) on public.profiles to authenticated;

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, display_name, account_type)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name', ''),
          case when new.raw_user_meta_data->>'account_type' = 'pro' then 'pro' else 'user' end);
  insert into public.user_data (user_id) values (new.id);
  return new;
end $$;
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- Dati privati dell'utente (planner, dispensa, preferenze): nessun altro li legge
create table public.user_data (
  user_id uuid primary key references auth.users(id) on delete cascade,
  planner jsonb not null default '{}',
  pantry jsonb not null default '[]',
  prefs jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
alter table public.user_data enable row level security;
create policy "solo il proprietario" on public.user_data for all to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Ricette ---------------------------------------------------------------
create table public.recipes (
  id bigint generated always as identity primary key,
  author_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 80),
  tag text not null default 'Altro',
  time_min int not null default 30 check (time_min > 0),
  serv int not null default 2 check (serv between 1 and 50),
  media_url text,
  ingredients jsonb not null default '[]',
  steps jsonb not null default '[]',
  hide_nutrition boolean not null default false,
  from_recipe_id bigint references public.recipes(id) on delete set null,
  created_at timestamptz not null default now()
);
create index on public.recipes (author_id);
create index on public.recipes (created_at desc);
alter table public.recipes enable row level security;
create policy "ricette visibili agli utenti" on public.recipes for select to authenticated using (true);
create policy "autore inserisce" on public.recipes for insert to authenticated with check ((select auth.uid()) = author_id);
create policy "autore modifica" on public.recipes for update to authenticated
  using ((select auth.uid()) = author_id) with check ((select auth.uid()) = author_id);
create policy "autore elimina" on public.recipes for delete to authenticated using ((select auth.uid()) = author_id);

create table public.likes (
  user_id uuid not null references public.profiles(id) on delete cascade,
  recipe_id bigint not null references public.recipes(id) on delete cascade,
  primary key (user_id, recipe_id)
);
create table public.saves (
  user_id uuid not null references public.profiles(id) on delete cascade,
  recipe_id bigint not null references public.recipes(id) on delete cascade,
  folder text,
  primary key (user_id, recipe_id)
);
create table public.follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  followed_id uuid not null references public.profiles(id) on delete cascade,
  primary key (follower_id, followed_id),
  check (follower_id <> followed_id)
);
create index on public.likes (recipe_id);
create index on public.saves (recipe_id);
create index on public.follows (followed_id);
alter table public.likes enable row level security;
alter table public.saves enable row level security;
alter table public.follows enable row level security;
create policy "mi piace visibili" on public.likes for select to authenticated using (true);
create policy "metto mi piace" on public.likes for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "tolgo mi piace" on public.likes for delete to authenticated using ((select auth.uid()) = user_id);
create policy "vedo i miei salvati" on public.saves for select to authenticated using ((select auth.uid()) = user_id);
create policy "salvo" on public.saves for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "sposto in cartella" on public.saves for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "tolgo dai salvati" on public.saves for delete to authenticated using ((select auth.uid()) = user_id);
create policy "follow visibili" on public.follows for select to authenticated using (true);
create policy "seguo" on public.follows for insert to authenticated with check ((select auth.uid()) = follower_id);
create policy "smetto di seguire" on public.follows for delete to authenticated using ((select auth.uid()) = follower_id);

create table public.comments (
  id bigint generated always as identity primary key,
  recipe_id bigint not null references public.recipes(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 300),
  created_at timestamptz not null default now()
);
create index on public.comments (recipe_id);
alter table public.comments enable row level security;
create policy "commenti visibili" on public.comments for select to authenticated using (true);
create policy "commento" on public.comments for insert to authenticated with check ((select auth.uid()) = author_id);
create policy "elimino il mio commento" on public.comments for delete to authenticated using ((select auth.uid()) = author_id);

-- Nutrizionista e cliente -------------------------------------------------
create table public.client_links (
  id bigint generated always as identity primary key,
  pro_id uuid not null references public.profiles(id) on delete cascade,
  client_id uuid references public.profiles(id) on delete cascade,
  invite_code text not null unique default replace(gen_random_uuid()::text, '-', ''),
  status text not null default 'pending' check (status in ('pending','active','ended')),
  created_at timestamptz not null default now()
);
create index on public.client_links (pro_id);
create index on public.client_links (client_id);
alter table public.client_links enable row level security;
create policy "vedo i miei collegamenti" on public.client_links for select to authenticated
  using ((select auth.uid()) in (pro_id, client_id));
create policy "solo un professionista verificato invita" on public.client_links for insert to authenticated
  with check ((select auth.uid()) = pro_id and status = 'pending' and client_id is null
    and exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.pro_verified));
create policy "chiudo il collegamento" on public.client_links for update to authenticated
  using ((select auth.uid()) in (pro_id, client_id))
  with check ((select auth.uid()) in (pro_id, client_id) and status = 'ended');

create function public.accept_invite(code text) returns bigint
language plpgsql security definer set search_path = '' as $$
declare l public.client_links;
begin
  if (select auth.uid()) is null then raise exception 'non autenticato'; end if;
  select * into l from public.client_links where invite_code = code and status = 'pending' and client_id is null for update;
  if not found then raise exception 'invito non valido'; end if;
  if l.pro_id = (select auth.uid()) then raise exception 'non puoi accettare il tuo invito'; end if;
  update public.client_links set client_id = (select auth.uid()), status = 'active' where id = l.id;
  return l.id;
end $$;
revoke execute on function public.accept_invite(text) from public, anon;
grant execute on function public.accept_invite(text) to authenticated;

create table public.plans (
  id bigint generated always as identity primary key,
  link_id bigint not null references public.client_links(id) on delete cascade,
  title text not null default 'Piano settimanale',
  data jsonb not null default '{}',
  kcal_goal int check (kcal_goal between 800 and 6000),
  created_at timestamptz not null default now()
);
create index on public.plans (link_id);
alter table public.plans enable row level security;
create policy "piano visibile a professionista e cliente" on public.plans for select to authenticated
  using (exists (select 1 from public.client_links l where l.id = link_id and (select auth.uid()) in (l.pro_id, l.client_id)));
create policy "il professionista scrive il piano" on public.plans for insert to authenticated
  with check (exists (select 1 from public.client_links l where l.id = link_id and l.pro_id = (select auth.uid()) and l.status = 'active'));
create policy "il professionista modifica il piano" on public.plans for update to authenticated
  using (exists (select 1 from public.client_links l where l.id = link_id and l.pro_id = (select auth.uid())))
  with check (exists (select 1 from public.client_links l where l.id = link_id and l.pro_id = (select auth.uid())));
create policy "il professionista elimina il piano" on public.plans for delete to authenticated
  using (exists (select 1 from public.client_links l where l.id = link_id and l.pro_id = (select auth.uid())));

create table public.messages (
  id bigint generated always as identity primary key,
  link_id bigint not null references public.client_links(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  body text check (char_length(body) <= 300),
  recipe_id bigint references public.recipes(id) on delete set null,
  created_at timestamptz not null default now(),
  check (body is not null or recipe_id is not null)
);
create index on public.messages (link_id, created_at);
alter table public.messages enable row level security;
create policy "leggo i messaggi del mio collegamento" on public.messages for select to authenticated
  using (exists (select 1 from public.client_links l where l.id = link_id and (select auth.uid()) in (l.pro_id, l.client_id)));
create policy "scrivo nel mio collegamento attivo" on public.messages for insert to authenticated
  with check ((select auth.uid()) = sender_id
    and exists (select 1 from public.client_links l where l.id = link_id and l.status = 'active' and (select auth.uid()) in (l.pro_id, l.client_id)));
