-- Ricettario personale: ricette salvate come "solo per me", visibili esclusivamente all'autore.
-- Non compaiono in feed, ricerca, profilo, notifiche, ne' ai seguaci; non si possono commentare o mettere tra i mi piace.
alter table public.recipes add column is_private boolean not null default false;
create index recipes_private_idx on public.recipes (author_id) where is_private;

drop policy "ricette visibili" on public.recipes;
create policy "ricette visibili" on public.recipes for select to authenticated using (
  (select auth.uid()) = author_id
  or (not is_private and (
    (for_link_id is not null and exists (select 1 from public.client_links l
          where l.id = for_link_id and l.client_id = (select auth.uid()) and l.status = 'active'))
    or (for_link_id is null and not private.blocked_pair(author_id) and (
      exists (select 1 from public.profiles p where p.id = author_id and not p.is_private)
      or exists (select 1 from public.follows f where f.follower_id = (select auth.uid()) and f.followed_id = author_id and f.status = 'accepted'))))));

-- Il pannello admin conta solo i piatti pubblici (la vista esclude anche le ricette private).
create or replace view public.recipes_public as select * from public.recipes where for_link_id is null and not is_private;
revoke all on public.recipes_public from public, anon, authenticated;
