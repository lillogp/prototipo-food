-- Segreti: fino a 2 ingredienti e 2 passaggi per ricetta, visibili solo a chi l'autore autorizza.
-- Nella ricetta pubblica resta solo un segnaposto; il contenuto vero sta in recipe_secrets.

alter table public.notifications drop constraint notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('follow','follow_request','follow_accepted','like','comment','comment_like','client_joined','plan','message','dm','dm_request','story_like','admin_warning','secret_request','secret_accepted'));

create table public.recipe_secrets (
  recipe_id bigint not null references public.recipes(id) on delete cascade,
  kind text not null check (kind in ('ing', 'step')),
  idx int not null check (idx between 0 and 199),
  content jsonb not null check (char_length(content::text) <= 600),
  primary key (recipe_id, kind, idx)
);
alter table public.recipe_secrets enable row level security;

create table public.secret_requests (
  id bigint generated always as identity primary key,
  recipe_id bigint not null references public.recipes(id) on delete cascade,
  requester_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  unique (recipe_id, requester_id)
);
create index on public.secret_requests (recipe_id);
alter table public.secret_requests enable row level security;

create function public.is_recipe_author(rid bigint) returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.recipes where id = rid and author_id = (select auth.uid()))
$$;
create function public.has_secret_access(rid bigint) returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_recipe_author(rid) or exists (
    select 1 from public.secret_requests where recipe_id = rid and requester_id = (select auth.uid()) and status = 'accepted')
$$;
create function public.recipe_has_secrets(rid bigint) returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.recipe_secrets where recipe_id = rid)
$$;
revoke execute on function public.is_recipe_author(bigint), public.has_secret_access(bigint), public.recipe_has_secrets(bigint) from public, anon;
grant execute on function public.is_recipe_author(bigint), public.has_secret_access(bigint), public.recipe_has_secrets(bigint) to authenticated;

create policy "vedo i segreti se autorizzato" on public.recipe_secrets for select to authenticated using (public.has_secret_access(recipe_id));
create policy "autore inserisce segreti" on public.recipe_secrets for insert to authenticated with check (public.is_recipe_author(recipe_id));
create policy "autore modifica segreti" on public.recipe_secrets for update to authenticated using (public.is_recipe_author(recipe_id)) with check (public.is_recipe_author(recipe_id));
create policy "autore elimina segreti" on public.recipe_secrets for delete to authenticated using (public.is_recipe_author(recipe_id));

create function public.secret_cap() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.recipe_secrets where recipe_id = new.recipe_id and kind = new.kind) >= 2 then
    raise exception 'massimo 2 segreti per tipo';
  end if;
  return new;
end $$;
create trigger trg_secret_cap before insert on public.recipe_secrets for each row execute function public.secret_cap();

create policy "vedo le mie richieste e quelle sulle mie ricette" on public.secret_requests for select to authenticated
  using (requester_id = (select auth.uid()) or public.is_recipe_author(recipe_id));
create policy "chiedo i segreti" on public.secret_requests for insert to authenticated
  with check (requester_id = (select auth.uid()) and status = 'pending' and not public.is_recipe_author(recipe_id)
    and public.recipe_has_secrets(recipe_id));
create policy "autore risponde" on public.secret_requests for update to authenticated
  using (public.is_recipe_author(recipe_id)) with check (public.is_recipe_author(recipe_id) and status in ('accepted', 'declined'));
create policy "annullo o revoco" on public.secret_requests for delete to authenticated
  using (requester_id = (select auth.uid()) or public.is_recipe_author(recipe_id));
revoke update on public.secret_requests from authenticated;
grant update (status) on public.secret_requests to authenticated;

create function public.notify_secret_request() returns trigger language plpgsql security definer set search_path = '' as $$
declare a uuid; t text;
begin
  select author_id, title into a, t from public.recipes where id = new.recipe_id;
  if a is not null then
    insert into public.notifications (user_id, actor_id, type, ref)
    values (a, new.requester_id, 'secret_request', jsonb_build_object('recipe_id', new.recipe_id, 'request_id', new.id, 'title', t));
  end if;
  return new;
end $$;
create trigger trg_notify_secret_request after insert on public.secret_requests for each row execute function public.notify_secret_request();

create function public.notify_secret_answer() returns trigger language plpgsql security definer set search_path = '' as $$
declare a uuid; t text;
begin
  delete from public.notifications where type = 'secret_request' and ref->>'request_id' = new.id::text;
  if new.status = 'accepted' then
    select author_id, title into a, t from public.recipes where id = new.recipe_id;
    insert into public.notifications (user_id, actor_id, type, ref)
    values (new.requester_id, a, 'secret_accepted', jsonb_build_object('recipe_id', new.recipe_id, 'title', t));
  end if;
  return new;
end $$;
create trigger trg_notify_secret_answer after update of status on public.secret_requests for each row
  when (old.status = 'pending' and new.status <> 'pending') execute function public.notify_secret_answer();

create function public.notify_secret_cancel() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.notifications where type = 'secret_request' and ref->>'request_id' = old.id::text;
  return old;
end $$;
create trigger trg_notify_secret_cancel after delete on public.secret_requests for each row execute function public.notify_secret_cancel();

revoke execute on function public.secret_cap(), public.notify_secret_request(), public.notify_secret_answer(), public.notify_secret_cancel() from public, anon, authenticated;
