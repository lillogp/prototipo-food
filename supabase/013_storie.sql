-- Storie: foto che durano 24 ore, visibili a chi ti segue (e a te).
create table public.stories (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  media_url text not null,
  media_path text not null,
  caption text check (caption is null or char_length(caption) <= 140),
  recipe_id bigint references public.recipes(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours'
);
create index on public.stories (author_id, created_at);
create index on public.stories (expires_at);
alter table public.stories enable row level security;

create policy "storie visibili" on public.stories for select to authenticated using (
  expires_at > now() and (
    (select auth.uid()) = author_id
    or (not private.blocked_pair(author_id)
        and exists (select 1 from public.follows f where f.follower_id = (select auth.uid()) and f.followed_id = author_id and f.status = 'accepted'))));
create policy "pubblico una storia" on public.stories for insert to authenticated
  with check ((select auth.uid()) = author_id);
create policy "elimino le mie storie" on public.stories for delete to authenticated
  using ((select auth.uid()) = author_id);

create table public.story_views (
  story_id uuid not null references public.stories(id) on delete cascade,
  viewer_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (story_id, viewer_id)
);
alter table public.story_views enable row level security;
create policy "vedo chi ha visto" on public.story_views for select to authenticated using (
  viewer_id = (select auth.uid())
  or exists (select 1 from public.stories s where s.id = story_id and s.author_id = (select auth.uid())));
create policy "segno come vista" on public.story_views for insert to authenticated
  with check (viewer_id = (select auth.uid()) and exists (select 1 from public.stories s where s.id = story_id));
