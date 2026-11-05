-- Pannello admin professionale: panoramica, dettagli di utenti e piatti, registro delle azioni.

create table public.admin_log (
  id bigint generated always as identity primary key,
  admin_id uuid references auth.users(id) on delete set null,
  admin_name text,
  action text not null check (char_length(action) <= 40),
  target text check (char_length(target) <= 200),
  created_at timestamptz not null default now()
);
alter table public.admin_log enable row level security;
revoke all on public.admin_log from anon, authenticated;

create function public.admin_log_add(act text, tgt text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  insert into public.admin_log (admin_id, admin_name, action, target)
    values ((select auth.uid()), (select display_name from public.profiles where id = (select auth.uid())), left(act, 40), left(tgt, 200));
end $$;

create function public.admin_log_list(lim int default 60) returns table (id bigint, admin_name text, action text, target text, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  return query select l.id, l.admin_name, l.action, l.target, l.created_at from public.admin_log l order by l.created_at desc limit least(coalesce(lim, 60), 200);
end $$;

create function public.admin_overview() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r jsonb;
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  select jsonb_build_object(
    'users', (select count(*) from public.profiles),
    'users_7d', (select count(*) from public.profiles where created_at > now() - interval '7 days'),
    'users_prev_7d', (select count(*) from public.profiles where created_at between now() - interval '14 days' and now() - interval '7 days'),
    'users_today', (select count(*) from public.profiles where created_at > date_trunc('day', now())),
    'suspended', (select count(*) from public.profiles where suspended),
    'private', (select count(*) from public.profiles where is_private),
    'pros', (select count(*) from public.profiles where account_type = 'pro'),
    'pros_verified', (select count(*) from public.profiles where account_type = 'pro' and pro_verified),
    'recipes', (select count(*) from public.recipes),
    'recipes_7d', (select count(*) from public.recipes where created_at > now() - interval '7 days'),
    'recipes_prev_7d', (select count(*) from public.recipes where created_at between now() - interval '14 days' and now() - interval '7 days'),
    'comments', (select count(*) from public.comments),
    'comments_7d', (select count(*) from public.comments where created_at > now() - interval '7 days'),
    'likes', (select count(*) from public.likes),
    'saves', (select count(*) from public.saves),
    'follows', (select count(*) from public.follows),
    'convs', (select count(*) from public.conversations),
    'dms', (select count(*) from public.dm_messages),
    'dms_7d', (select count(*) from public.dm_messages where created_at > now() - interval '7 days'),
    'stories_active', (select count(*) from public.stories where expires_at > now()),
    'stories_total', (select count(*) from public.stories),
    'story_views', (select count(*) from public.story_views),
    'push', (select count(*) from public.push_subscriptions),
    'reports_open', (select count(*) from public.reports where status = 'open'),
    'reports_total', (select count(*) from public.reports),
    'active_7d', (select count(distinct a) from (
        select author_id a from public.recipes where created_at > now() - interval '7 days'
        union select author_id from public.comments where created_at > now() - interval '7 days'
        union select sender_id from public.dm_messages where created_at > now() - interval '7 days') x),
    'db_bytes', pg_database_size(current_database()),
    'storage_bytes', (select coalesce(sum((metadata ->> 'size')::bigint), 0) from storage.objects where bucket_id = 'media'),
    'storage_files', (select count(*) from storage.objects where bucket_id = 'media'),
    'series', (select coalesce(jsonb_agg(jsonb_build_object('d', to_char(g.d, 'YYYY-MM-DD'),
        'u', (select count(*) from public.profiles p where p.created_at >= g.d and p.created_at < g.d + interval '1 day'),
        'r', (select count(*) from public.recipes x where x.created_at >= g.d and x.created_at < g.d + interval '1 day'),
        'c', (select count(*) from public.comments x where x.created_at >= g.d and x.created_at < g.d + interval '1 day')) order by g.d), '[]'::jsonb)
      from generate_series(date_trunc('day', now()) - interval '29 days', date_trunc('day', now()), interval '1 day') g(d)),
    'top_recipes', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select r.id, r.title, r.media_url, p.display_name as author, (select count(*) from public.likes l where l.recipe_id = r.id) as likes,
               (select count(*) from public.saves s where s.recipe_id = r.id) as saves
        from public.recipes r join public.profiles p on p.id = r.author_id order by 5 desc, 6 desc, r.created_at desc limit 5) t),
    'top_users', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select p.id, p.display_name as name, p.handle, (select count(*) from public.follows f where f.followed_id = p.id) as followers,
               (select count(*) from public.recipes r where r.author_id = p.id) as recipes
        from public.profiles p order by 4 desc, 5 desc limit 5) t),
    'tags', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (select tag, count(*) as n from public.recipes group by tag order by 2 desc limit 8) t),
    'recent', (select coalesce(jsonb_agg(t order by (t ->> 'at') desc), '[]'::jsonb) from (
        select * from (
          select jsonb_build_object('k', 'user', 'at', p.created_at, 'who', p.display_name, 'id', p.id) t from public.profiles p order by p.created_at desc limit 8) a
        union all select * from (
          select jsonb_build_object('k', 'recipe', 'at', r.created_at, 'who', p.display_name, 'what', r.title, 'id', r.id) from public.recipes r join public.profiles p on p.id = r.author_id order by r.created_at desc limit 8) b
        union all select * from (
          select jsonb_build_object('k', 'report', 'at', x.created_at, 'who', p.display_name, 'what', x.reason, 'id', x.id) from public.reports x join public.profiles p on p.id = x.reported_id order by x.created_at desc limit 5) c
      ) u)
  ) into r;
  return r;
end $$;

create function public.admin_user_detail(uid uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r jsonb;
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  select jsonb_build_object(
    'id', p.id, 'name', p.display_name, 'handle', p.handle, 'email', u.email, 'avatar', p.avatar_url, 'type', p.account_type, 'title', p.pro_title,
    'verified', p.pro_verified, 'suspended', p.suspended, 'admin', p.is_admin, 'private', p.is_private,
    'created_at', p.created_at, 'last_sign_in', u.last_sign_in_at, 'confirmed', u.email_confirmed_at is not null,
    'terms_version', u.raw_user_meta_data ->> 'terms_version', 'terms_at', u.raw_user_meta_data ->> 'terms_at',
    'recipes', (select count(*) from public.recipes where author_id = p.id),
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
    'last_recipes', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (select id, title, media_url, created_at from public.recipes where author_id = p.id order by created_at desc limit 6) t),
    'last_comments', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (select c.id, c.body, c.created_at, r.title from public.comments c left join public.recipes r on r.id = c.recipe_id where c.author_id = p.id order by c.created_at desc limit 5) t),
    'reports', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (select x.id, x.reason, x.details, x.status, x.created_at, x.content_type from public.reports x where x.reported_id = p.id order by x.created_at desc limit 10) t)
  ) into r
  from public.profiles p join auth.users u on u.id = p.id where p.id = uid;
  return r;
end $$;

create function public.admin_recipe_detail(rid bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r jsonb;
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  select jsonb_build_object(
    'id', x.id, 'title', x.title, 'tag', x.tag, 'time_min', x.time_min, 'serv', x.serv, 'media_url', x.media_url,
    'ingredients', x.ingredients, 'steps', x.steps, 'created_at', x.created_at,
    'author_id', x.author_id, 'author', p.display_name, 'handle', p.handle,
    'likes', (select count(*) from public.likes where recipe_id = x.id),
    'saves', (select count(*) from public.saves where recipe_id = x.id),
    'comments', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (select c.id, c.body, c.created_at, q.display_name as who from public.comments c join public.profiles q on q.id = c.author_id where c.recipe_id = x.id order by c.created_at desc limit 20) t),
    'reports', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (select s.id, s.reason, s.details, s.status, s.created_at from public.reports s where s.content_type = 'recipe' and s.content_id = x.id::text order by s.created_at desc limit 10) t)
  ) into r
  from public.recipes x join public.profiles p on p.id = x.author_id where x.id = rid;
  return r;
end $$;

revoke execute on function public.admin_log_add(text, text), public.admin_log_list(int), public.admin_overview(), public.admin_user_detail(uuid), public.admin_recipe_detail(bigint) from public, anon;
grant execute on function public.admin_log_add(text, text), public.admin_log_list(int), public.admin_overview(), public.admin_user_detail(uuid), public.admin_recipe_detail(bigint) to authenticated;
