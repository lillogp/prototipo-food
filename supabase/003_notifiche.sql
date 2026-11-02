-- Notifiche: follow, richieste, mi piace, commenti, clienti, piani e messaggi.
create table public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete cascade,
  type text not null check (type in ('follow','follow_request','follow_accepted','like','comment','client_joined','plan','message')),
  ref jsonb not null default '{}',
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index on public.notifications (user_id, created_at desc);
alter table public.notifications enable row level security;
create policy "leggo le mie notifiche" on public.notifications for select to authenticated using ((select auth.uid()) = user_id);
create policy "segno come lette" on public.notifications for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "elimino le mie notifiche" on public.notifications for delete to authenticated using ((select auth.uid()) = user_id);
revoke update on public.notifications from authenticated;
grant update (read_at) on public.notifications to authenticated;

create function public.notify_follow() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.notifications (user_id, actor_id, type)
  values (new.followed_id, new.follower_id, case when new.status = 'pending' then 'follow_request' else 'follow' end);
  return new;
end $$;
create trigger trg_notify_follow after insert on public.follows for each row execute function public.notify_follow();

create function public.notify_follow_accept() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.notifications where user_id = new.followed_id and actor_id = new.follower_id and type = 'follow_request';
  insert into public.notifications (user_id, actor_id, type) values (new.follower_id, new.followed_id, 'follow_accepted');
  return new;
end $$;
create trigger trg_notify_follow_accept after update of status on public.follows for each row
  when (old.status = 'pending' and new.status = 'accepted') execute function public.notify_follow_accept();

create function public.notify_follow_cancel() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.notifications where user_id = old.followed_id and actor_id = old.follower_id and type in ('follow_request', 'follow');
  return old;
end $$;
create trigger trg_notify_follow_cancel after delete on public.follows for each row execute function public.notify_follow_cancel();

create function public.notify_like() returns trigger language plpgsql security definer set search_path = '' as $$
declare a uuid;
begin
  select author_id into a from public.recipes where id = new.recipe_id;
  if a is not null and a <> new.user_id then
    insert into public.notifications (user_id, actor_id, type, ref) values (a, new.user_id, 'like', jsonb_build_object('recipe_id', new.recipe_id));
  end if;
  return new;
end $$;
create trigger trg_notify_like after insert on public.likes for each row execute function public.notify_like();

create function public.notify_comment() returns trigger language plpgsql security definer set search_path = '' as $$
declare a uuid;
begin
  select author_id into a from public.recipes where id = new.recipe_id;
  if a is not null and a <> new.author_id then
    insert into public.notifications (user_id, actor_id, type, ref) values (a, new.author_id, 'comment', jsonb_build_object('recipe_id', new.recipe_id));
  end if;
  return new;
end $$;
create trigger trg_notify_comment after insert on public.comments for each row execute function public.notify_comment();

create function public.notify_client_joined() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.notifications (user_id, actor_id, type, ref) values (new.pro_id, new.client_id, 'client_joined', jsonb_build_object('link_id', new.id));
  return new;
end $$;
create trigger trg_notify_client_joined after update of status on public.client_links for each row
  when (old.status = 'pending' and new.status = 'active') execute function public.notify_client_joined();

create function public.notify_plan() returns trigger language plpgsql security definer set search_path = '' as $$
declare c uuid; p uuid;
begin
  select client_id, pro_id into c, p from public.client_links where id = new.link_id;
  if c is not null then
    insert into public.notifications (user_id, actor_id, type, ref) values (c, p, 'plan', jsonb_build_object('link_id', new.link_id));
  end if;
  return new;
end $$;
create trigger trg_notify_plan after insert on public.plans for each row execute function public.notify_plan();

create function public.notify_message() returns trigger language plpgsql security definer set search_path = '' as $$
declare p uuid; c uuid; r uuid;
begin
  select pro_id, client_id into p, c from public.client_links where id = new.link_id;
  r := case when new.sender_id = p then c else p end;
  if r is not null and not exists (
    select 1 from public.notifications where user_id = r and type = 'message' and read_at is null and ref->>'link_id' = new.link_id::text
  ) then
    insert into public.notifications (user_id, actor_id, type, ref) values (r, new.sender_id, 'message', jsonb_build_object('link_id', new.link_id));
  end if;
  return new;
end $$;
create trigger trg_notify_message after insert on public.messages for each row execute function public.notify_message();

revoke execute on function public.notify_follow(), public.notify_follow_accept(), public.notify_follow_cancel(), public.notify_like(),
  public.notify_comment(), public.notify_client_joined(), public.notify_plan(), public.notify_message() from public, anon, authenticated;
