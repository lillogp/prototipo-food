-- Mi piace alle storie + notifica a chi le ha pubblicate.
create table public.story_likes (
  story_id uuid not null references public.stories(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (story_id, user_id)
);
alter table public.story_likes enable row level security;
create policy "vedo i mi piace delle storie" on public.story_likes for select to authenticated using (
  user_id = (select auth.uid())
  or exists (select 1 from public.stories s where s.id = story_id and s.author_id = (select auth.uid())));
create policy "metto mi piace alla storia" on public.story_likes for insert to authenticated
  with check (user_id = (select auth.uid()) and exists (select 1 from public.stories s where s.id = story_id));
create policy "tolgo il mio mi piace" on public.story_likes for delete to authenticated using (user_id = (select auth.uid()));

alter table public.notifications drop constraint notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('follow','follow_request','follow_accepted','like','comment','comment_like','client_joined','plan','message','dm','dm_request','story_like'));

create function public.notify_story_like() returns trigger language plpgsql security definer set search_path = '' as $$
declare a uuid;
begin
  select author_id into a from public.stories where id = new.story_id;
  if a is not null and a <> new.user_id then
    insert into public.notifications (user_id, actor_id, type, ref) values (a, new.user_id, 'story_like', jsonb_build_object('story_id', new.story_id));
  end if;
  return new;
end $$;
create trigger trg_notify_story_like after insert on public.story_likes for each row execute function public.notify_story_like();
revoke execute on function public.notify_story_like() from public, anon, authenticated;
