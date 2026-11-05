-- Avvisi dell'amministrazione a un utente (a senso unico): notifica in app + storico visibile solo agli admin.
alter table public.notifications drop constraint notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('follow','follow_request','follow_accepted','like','comment','comment_like','client_joined','plan','message','dm','dm_request','story_like','admin_warning'));

create table public.admin_warnings (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  admin_id uuid references public.profiles(id) on delete set null,
  reason text not null check (char_length(reason) <= 60),
  body text not null check (char_length(body) between 1 and 300),
  created_at timestamptz not null default now()
);
create index on public.admin_warnings (user_id, created_at desc);
alter table public.admin_warnings enable row level security; -- nessuna policy: la leggono solo le funzioni admin

create function public.admin_warn_user(target uuid, reason text, msg text) returns void
language plpgsql security definer set search_path = '' as $$
declare wid bigint; m text := btrim(coalesce(msg, '')); rs text := left(btrim(coalesce(reason, '')), 60);
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  if char_length(m) < 1 or char_length(m) > 300 then raise exception 'testo non valido'; end if;
  if not exists (select 1 from public.profiles where id = target) then raise exception 'utente non trovato'; end if;
  insert into public.admin_warnings (user_id, admin_id, reason, body) values (target, (select auth.uid()), rs, m) returning id into wid;
  insert into public.notifications (user_id, actor_id, type, ref) values (target, null, 'admin_warning', jsonb_build_object('reason', rs, 'body', m, 'wid', wid));
end $$;
revoke execute on function public.admin_warn_user(uuid, text, text) from public, anon;
grant execute on function public.admin_warn_user(uuid, text, text) to authenticated;

create or replace function public.admin_user_detail(uid uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r jsonb;
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  select jsonb_build_object(
    'id', p.id, 'name', p.display_name, 'handle', p.handle, 'email', u.email, 'avatar', p.avatar_url, 'type', p.account_type, 'title', p.pro_title,
    'verified', p.pro_verified, 'suspended', p.suspended, 'admin', p.is_admin, 'private', p.is_private, 'bio', p.bio,
    'created_at', p.created_at, 'last_sign_in', u.last_sign_in_at, 'confirmed', u.email_confirmed_at is not null,
    'terms_version', u.raw_user_meta_data ->> 'terms_version', 'terms_at', u.raw_user_meta_data ->> 'terms_at',
    'recipes', (select count(*) from public.recipes_public where author_id = p.id),
    'comments', (select count(*) from public.comments where author_id = p.id),
    'likes_given', (select count(*) from public.likes where user_id = p.id),
    'saves', (select count(*) from public.saves where user_id = p.id),
    'followers', (select count(*) from public.follows where followed_id = p.id),
    'following', (select count(*) from public.follows where follower_id = p.id),
    'stories', (select count(*) from public.stories where author_id = p.id),
    'dms_sent', (select count(*) from public.dm_messages where sender_id = p.id),
    'push', (select count(*) from public.push_subscriptions where user_id = p.id),
    'reports_received', (select count(*) from public.reports where reported_id = p.id),
    'reports_made', (select count(*) from public.reports where reporter_id = p.id),
    'blocked_by', (select count(*) from public.blocks where blocked_id = p.id),
    'last_recipes', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (select id, title, media_url, created_at from public.recipes_public where author_id = p.id order by created_at desc limit 6) t),
    'last_comments', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (select c.id, c.body, c.created_at, r.title from public.comments c left join public.recipes_public r on r.id = c.recipe_id where c.author_id = p.id order by c.created_at desc limit 5) t),
    'reports', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (select x.id, x.reason, x.details, x.status, x.created_at, x.content_type from public.reports x where x.reported_id = p.id order by x.created_at desc limit 10) t),
    'warnings', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (select w.reason, w.body, w.created_at from public.admin_warnings w where w.user_id = p.id order by w.created_at desc limit 10) t)
  ) into r
  from public.profiles p join auth.users u on u.id = p.id where p.id = uid;
  return r;
end $$;
