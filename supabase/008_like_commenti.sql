-- Mi piace sui commenti (visibili solo se la ricetta e' visibile) e relativa notifica.
create table public.comment_likes (
  user_id uuid not null references public.profiles(id) on delete cascade,
  comment_id bigint not null references public.comments(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, comment_id)
);
create index on public.comment_likes (comment_id);
alter table public.comment_likes enable row level security;
create policy "vedo i mi piace dei commenti" on public.comment_likes for select to authenticated
  using (exists (select 1 from public.comments c where c.id = comment_id));
create policy "metto mi piace a un commento" on public.comment_likes for insert to authenticated
  with check ((select auth.uid()) = user_id and exists (select 1 from public.comments c where c.id = comment_id));
create policy "tolgo il mi piace a un commento" on public.comment_likes for delete to authenticated
  using ((select auth.uid()) = user_id);

alter table public.notifications drop constraint notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('follow','follow_request','follow_accepted','like','comment','comment_like','client_joined','plan','message','dm','dm_request'));

create function public.notify_comment_like() returns trigger language plpgsql security definer set search_path = '' as $$
declare a uuid; rid bigint;
begin
  select author_id, recipe_id into a, rid from public.comments where id = new.comment_id;
  if a is not null and a <> new.user_id then
    insert into public.notifications (user_id, actor_id, type, ref)
    values (a, new.user_id, 'comment_like', jsonb_build_object('recipe_id', rid, 'comment_id', new.comment_id));
  end if;
  return new;
end $$;
create trigger trg_notify_comment_like after insert on public.comment_likes for each row execute function public.notify_comment_like();
revoke execute on function public.notify_comment_like() from public, anon, authenticated;
