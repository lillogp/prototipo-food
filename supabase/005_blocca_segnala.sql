-- Blocca e segnala. Il blocco e' reciproco: chi blocca e chi e' bloccato non si vedono piu.
create schema if not exists private;
grant usage on schema private to authenticated;

create table public.blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  blocked_name text not null default '',
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index on public.blocks (blocked_id);
alter table public.blocks enable row level security;
create policy "vedo i miei blocchi" on public.blocks for select to authenticated using ((select auth.uid()) = blocker_id);
create policy "blocco" on public.blocks for insert to authenticated with check ((select auth.uid()) = blocker_id);
create policy "sblocco" on public.blocks for delete to authenticated using ((select auth.uid()) = blocker_id);

-- Controllo di blocco: schema privato (non esposto dall'API), cosi' nessuno puo' chiedere "mi ha bloccato?".
create function private.blocked_pair(other uuid) returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.blocks b
    where (b.blocker_id = (select auth.uid()) and b.blocked_id = other)
       or (b.blocker_id = other and b.blocked_id = (select auth.uid())));
$$;
revoke execute on function private.blocked_pair(uuid) from public, anon;
grant execute on function private.blocked_pair(uuid) to authenticated;

drop policy "profili visibili agli utenti" on public.profiles;
create policy "profili visibili" on public.profiles for select to authenticated using (not private.blocked_pair(id));

drop policy "ricette visibili" on public.recipes;
create policy "ricette visibili" on public.recipes for select to authenticated using (
  (select auth.uid()) = author_id
  or (not private.blocked_pair(author_id) and (
    exists (select 1 from public.profiles p where p.id = author_id and not p.is_private)
    or exists (select 1 from public.follows f where f.follower_id = (select auth.uid()) and f.followed_id = author_id and f.status = 'accepted'))));

drop policy "seguo o richiedo" on public.follows;
create policy "seguo o richiedo" on public.follows for insert to authenticated
  with check ((select auth.uid()) = follower_id and not private.blocked_pair(followed_id)
    and status = (case when exists (select 1 from public.profiles p where p.id = followed_id and p.is_private) then 'pending' else 'accepted' end));

drop policy "vedo le mie conversazioni" on public.conversations;
create policy "vedo le mie conversazioni" on public.conversations for select to authenticated
  using ((select auth.uid()) in (user_a, user_b)
    and not private.blocked_pair(case when (select auth.uid()) = user_a then user_b else user_a end));
drop policy "avvio una conversazione" on public.conversations;
create policy "avvio una conversazione" on public.conversations for insert to authenticated
  with check ((select auth.uid()) in (user_a, user_b)
    and not private.blocked_pair(case when (select auth.uid()) = user_a then user_b else user_a end));

drop policy "leggo i messaggi delle mie conversazioni" on public.dm_messages;
create policy "leggo i messaggi delle mie conversazioni" on public.dm_messages for select to authenticated
  using (exists (select 1 from public.conversations c where c.id = conv_id
    and (select auth.uid()) in (c.user_a, c.user_b)
    and not private.blocked_pair(case when (select auth.uid()) = c.user_a then c.user_b else c.user_a end)
    and not (c.status = 'declined' and (select auth.uid()) <> c.initiator)));
drop policy "scrivo nelle mie conversazioni" on public.dm_messages;
create policy "scrivo nelle mie conversazioni" on public.dm_messages for insert to authenticated
  with check ((select auth.uid()) = sender_id and exists (select 1 from public.conversations c where c.id = conv_id
    and (select auth.uid()) in (c.user_a, c.user_b)
    and not private.blocked_pair(case when (select auth.uid()) = c.user_a then c.user_b else c.user_a end)
    and (c.status = 'active' or (c.status = 'pending' and c.initiator = (select auth.uid())))));

-- Quando blocchi: sparisce ogni follow e ogni notifica tra voi.
create function public.on_block() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.follows where (follower_id = new.blocker_id and followed_id = new.blocked_id) or (follower_id = new.blocked_id and followed_id = new.blocker_id);
  delete from public.notifications where (user_id = new.blocker_id and actor_id = new.blocked_id) or (user_id = new.blocked_id and actor_id = new.blocker_id);
  return new;
end $$;
create trigger trg_on_block after insert on public.blocks for each row execute function public.on_block();
revoke execute on function public.on_block() from public, anon, authenticated;

create table public.reports (
  id bigint generated always as identity primary key,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reported_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null check (reason in ('spam','molestie','contenuto','falso','altro')),
  details text check (char_length(details) <= 500),
  conv_id bigint,
  status text not null default 'open' check (status in ('open','reviewed','closed')),
  created_at timestamptz not null default now(),
  check (reporter_id <> reported_id)
);
create unique index on public.reports (reporter_id, reported_id) where status = 'open';
create index on public.reports (reported_id);
alter table public.reports enable row level security;
create policy "invio una segnalazione" on public.reports for insert to authenticated with check ((select auth.uid()) = reporter_id);
create policy "vedo le mie segnalazioni" on public.reports for select to authenticated using ((select auth.uid()) = reporter_id);
