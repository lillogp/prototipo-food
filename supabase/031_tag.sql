-- Tag sulle ricette (stile Instagram): chi pubblica tagga delle persone, il taggato può ripubblicare.
-- Impostazione "chi può taggarti": everyone | following (solo persone che segui) | nobody.
alter table public.profiles add column tag_policy text not null default 'following' check (tag_policy in ('everyone','following','nobody'));
grant update (tag_policy) on public.profiles to authenticated;

create function private.can_tag_user(target uuid) returns boolean language sql stable security definer set search_path = '' as $$
  select target <> (select auth.uid()) and not private.blocked_pair(target) and coalesce((
    select case p.tag_policy
      when 'everyone' then true
      when 'following' then exists (select 1 from public.follows f where f.follower_id = target and f.followed_id = (select auth.uid()) and f.status = 'accepted')
      else false end
    from public.profiles p where p.id = target), false);
$$;
revoke execute on function private.can_tag_user(uuid) from public, anon;
grant execute on function private.can_tag_user(uuid) to authenticated;

create table public.recipe_tags (
  recipe_id bigint not null references public.recipes(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  tagged_by uuid not null references public.profiles(id) on delete cascade,
  reposted boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (recipe_id, user_id)
);
create index on public.recipe_tags (user_id) where reposted;
alter table public.recipe_tags enable row level security;
revoke all on public.recipe_tags from anon;
grant select, insert, delete on public.recipe_tags to authenticated;
grant update (reposted) on public.recipe_tags to authenticated;

create policy "tag visibili" on public.recipe_tags for select to authenticated
  using (exists (select 1 from public.recipes r where r.id = recipe_id));
create policy "taggo" on public.recipe_tags for insert to authenticated with check (
  tagged_by = (select auth.uid()) and user_id <> tagged_by
  and exists (select 1 from public.recipes r where r.id = recipe_id and r.author_id = tagged_by and not r.is_private and r.for_link_id is null)
  and private.can_tag_user(user_id));
create policy "ripubblico" on public.recipe_tags for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "tolgo il tag" on public.recipe_tags for delete to authenticated
  using (tagged_by = (select auth.uid()) or user_id = (select auth.uid()));

create function public.tag_limit() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.recipe_tags where recipe_id = new.recipe_id) >= 10 then raise exception 'massimo 10 persone taggate'; end if;
  return new;
end $$;
revoke execute on function public.tag_limit() from public, anon, authenticated;
create trigger trg_tag_limit before insert on public.recipe_tags for each row execute function public.tag_limit();

alter table public.notifications drop constraint notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('follow','follow_request','follow_accepted','like','comment','comment_like','client_joined','plan','message','dm','dm_request','story_like','admin_warning','secret_request','secret_accepted','tag'));

create function public.notify_tag() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.notifications (user_id, actor_id, type, ref) values (new.user_id, new.tagged_by, 'tag', jsonb_build_object('recipe_id', new.recipe_id));
  return new;
end $$;
revoke execute on function public.notify_tag() from public, anon, authenticated;
create trigger trg_notify_tag after insert on public.recipe_tags for each row execute function public.notify_tag();

create function public.notify_tag_remove() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.notifications where user_id = old.user_id and type = 'tag' and ref->>'recipe_id' = old.recipe_id::text;
  return old;
end $$;
revoke execute on function public.notify_tag_remove() from public, anon, authenticated;
create trigger trg_notify_tag_remove after delete on public.recipe_tags for each row execute function public.notify_tag_remove();
