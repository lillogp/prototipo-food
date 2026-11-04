-- Privacy delle storie: chi le vede, chi puo' rispondere, se le mie visualizzazioni sono visibili.
alter table public.profiles
  add column story_audience text not null default 'followers' check (story_audience in ('followers','mutual')),
  add column story_replies boolean not null default true,
  add column story_views_on boolean not null default true;
grant update (story_audience, story_replies, story_views_on) on public.profiles to authenticated;

drop policy "storie visibili" on public.stories;
create policy "storie visibili" on public.stories for select to authenticated using (
  expires_at > now() and (
    (select auth.uid()) = author_id
    or (not private.blocked_pair(author_id)
        and exists (select 1 from public.follows f where f.follower_id = (select auth.uid()) and f.followed_id = author_id and f.status = 'accepted')
        and (
          exists (select 1 from public.profiles p where p.id = author_id and p.story_audience = 'followers')
          or exists (select 1 from public.follows b where b.follower_id = author_id and b.followed_id = (select auth.uid()) and b.status = 'accepted')))));

drop policy "segno come vista" on public.story_views;
create policy "segno come vista" on public.story_views for insert to authenticated
  with check (viewer_id = (select auth.uid())
    and exists (select 1 from public.profiles p where p.id = viewer_id and p.story_views_on)
    and exists (select 1 from public.stories s where s.id = story_id));
