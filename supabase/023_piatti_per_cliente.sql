-- Piatti adattati per un cliente: copie private, visibili solo al nutrizionista che le ha create e al cliente del collegamento attivo.
-- Non compaiono nel feed, nella ricerca, nel profilo pubblico ne' nel pannello admin.
alter table public.recipes add column for_link_id bigint references public.client_links(id) on delete cascade;
create index recipes_for_link_idx on public.recipes (for_link_id) where for_link_id is not null;

drop policy "ricette visibili" on public.recipes;
create policy "ricette visibili" on public.recipes for select to authenticated using (
  (select auth.uid()) = author_id
  or (for_link_id is not null and exists (select 1 from public.client_links l
        where l.id = for_link_id and l.client_id = (select auth.uid()) and l.status = 'active'))
  or (for_link_id is null and not private.blocked_pair(author_id) and (
    exists (select 1 from public.profiles p where p.id = author_id and not p.is_private)
    or exists (select 1 from public.follows f where f.follower_id = (select auth.uid()) and f.followed_id = author_id and f.status = 'accepted'))));

drop policy "autore inserisce" on public.recipes;
create policy "autore inserisce" on public.recipes for insert to authenticated
  with check ((select auth.uid()) = author_id and (for_link_id is null or exists (select 1 from public.client_links l
        where l.id = for_link_id and l.pro_id = (select auth.uid()) and l.status = 'active')));
drop policy "autore modifica" on public.recipes;
create policy "autore modifica" on public.recipes for update to authenticated
  using ((select auth.uid()) = author_id)
  with check ((select auth.uid()) = author_id and (for_link_id is null or exists (select 1 from public.client_links l
        where l.id = for_link_id and l.pro_id = (select auth.uid()))));

-- Vista dei soli piatti pubblici, per le funzioni del pannello admin (nessun accesso agli utenti).
create view public.recipes_public as select * from public.recipes where for_link_id is null;
revoke all on public.recipes_public from public, anon, authenticated;

-- public.admin_dashboard (da 018_admin_moderazione.sql): esclude le copie private
create or replace function public.admin_dashboard() returns table (users bigint, new_users_7d bigint, pros bigint, pros_verified bigint, recipes bigint, stories_active bigint, open_reports bigint)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  return query select
    (select count(*) from public.profiles),
    (select count(*) from public.profiles where created_at > now() - interval '7 days'),
    (select count(*) from public.profiles where account_type = 'pro'),
    (select count(*) from public.profiles where account_type = 'pro' and pro_verified),
    (select count(*) from public.recipes_public),
    (select count(*) from public.stories where expires_at > now()),
    (select count(*) from public.reports where status = 'open');
end $$;

-- public.admin_users (da 018_admin_moderazione.sql): esclude le copie private
create or replace function public.admin_users(q text, lim int default 50, off int default 0) returns table (user_id uuid, name text, handle text, email text, account_type text, pro_verified boolean, suspended boolean, is_admin boolean, created_at timestamptz, recipes bigint, terms_version text)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  return query select p.id, p.display_name, p.handle, u.email::text, p.account_type, p.pro_verified, p.suspended, p.is_admin, p.created_at,
      (select count(*) from public.recipes_public r where r.author_id = p.id), (u.raw_user_meta_data ->> 'terms_version')
    from public.profiles p join auth.users u on u.id = p.id
    where coalesce(q, '') = '' or p.display_name ilike '%' || q || '%' or p.handle ilike '%' || q || '%' or u.email ilike '%' || q || '%'
    order by p.created_at desc limit least(coalesce(lim, 50), 200) offset greatest(coalesce(off, 0), 0);
end $$;

-- public.admin_recipes (da 018_admin_moderazione.sql): esclude le copie private
create or replace function public.admin_recipes(lim int default 40, off int default 0) returns table (recipe_id bigint, title text, author_id uuid, author_name text, media_url text, created_at timestamptz, open_reports bigint)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  return query select r.id, r.title, r.author_id, p.display_name, r.media_url, r.created_at,
      (select count(*) from public.reports x where x.content_type = 'recipe' and x.content_id = r.id::text and x.status = 'open')
    from public.recipes_public r join public.profiles p on p.id = r.author_id
    order by r.created_at desc limit least(coalesce(lim, 40), 100) offset greatest(coalesce(off, 0), 0);
end $$;

-- public.admin_comments (da 018_admin_moderazione.sql): esclude le copie private
create or replace function public.admin_comments(lim int default 50) returns table (comment_id bigint, body text, author_id uuid, author_name text, recipe_id bigint, recipe_title text, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  return query select c.id, c.body, c.author_id, p.display_name, c.recipe_id, r.title, c.created_at
    from public.comments c join public.profiles p on p.id = c.author_id left join public.recipes_public r on r.id = c.recipe_id
    order by c.created_at desc limit least(coalesce(lim, 50), 100);
end $$;

-- public.admin_reports2 (da 018_admin_moderazione.sql): esclude le copie private
create or replace function public.admin_reports2(st text) returns table (report_id bigint, reporter_id uuid, reporter_name text, reported_id uuid, reported_name text,
  reported_email text, reported_suspended boolean, reason text, details text, conv_id bigint, status text, created_at timestamptz,
  content_type text, content_id text, content_title text, content_media text)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  return query select r.id, r.reporter_id, rp.display_name, r.reported_id, rd.display_name, u.email::text, rd.suspended,
      r.reason, r.details, r.conv_id, r.status, r.created_at, r.content_type, r.content_id,
      (case when r.content_type = 'recipe' then (select x.title from public.recipes_public x where x.id::text = r.content_id) end),
      (case when r.content_type = 'recipe' then (select x.media_url from public.recipes_public x where x.id::text = r.content_id) end)
    from public.reports r
    join public.profiles rp on rp.id = r.reporter_id
    join public.profiles rd on rd.id = r.reported_id
    join auth.users u on u.id = r.reported_id
    where (st = 'open' and r.status = 'open') or (st <> 'open' and r.status <> 'open')
    order by r.created_at desc limit 100;
end $$;

-- public.admin_overview (da 019_admin_pro.sql): esclude le copie private
create or replace function public.admin_overview() returns jsonb
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
    'recipes', (select count(*) from public.recipes_public),
    'recipes_7d', (select count(*) from public.recipes_public where created_at > now() - interval '7 days'),
    'recipes_prev_7d', (select count(*) from public.recipes_public where created_at between now() - interval '14 days' and now() - interval '7 days'),
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
        select author_id a from public.recipes_public where created_at > now() - interval '7 days'
        union select author_id from public.comments where created_at > now() - interval '7 days'
        union select sender_id from public.dm_messages where created_at > now() - interval '7 days') x),
    'db_bytes', pg_database_size(current_database()),
    'storage_bytes', (select coalesce(sum((metadata ->> 'size')::bigint), 0) from storage.objects where bucket_id = 'media'),
    'storage_files', (select count(*) from storage.objects where bucket_id = 'media'),
    'series', (select coalesce(jsonb_agg(jsonb_build_object('d', to_char(g.d, 'YYYY-MM-DD'),
        'u', (select count(*) from public.profiles p where p.created_at >= g.d and p.created_at < g.d + interval '1 day'),
        'r', (select count(*) from public.recipes_public x where x.created_at >= g.d and x.created_at < g.d + interval '1 day'),
        'c', (select count(*) from public.comments x where x.created_at >= g.d and x.created_at < g.d + interval '1 day')) order by g.d), '[]'::jsonb)
      from generate_series(date_trunc('day', now()) - interval '29 days', date_trunc('day', now()), interval '1 day') g(d)),
    'top_recipes', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select r.id, r.title, r.media_url, p.display_name as author, (select count(*) from public.likes l where l.recipe_id = r.id) as likes,
               (select count(*) from public.saves s where s.recipe_id = r.id) as saves
        from public.recipes_public r join public.profiles p on p.id = r.author_id order by 5 desc, 6 desc, r.created_at desc limit 5) t),
    'top_users', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select p.id, p.display_name as name, p.handle, (select count(*) from public.follows f where f.followed_id = p.id) as followers,
               (select count(*) from public.recipes_public r where r.author_id = p.id) as recipes
        from public.profiles p order by 4 desc, 5 desc limit 5) t),
    'tags', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (select tag, count(*) as n from public.recipes_public group by tag order by 2 desc limit 8) t),
    'recent', (select coalesce(jsonb_agg(t order by (t ->> 'at') desc), '[]'::jsonb) from (
        select * from (
          select jsonb_build_object('k', 'user', 'at', p.created_at, 'who', p.display_name, 'id', p.id) t from public.profiles p order by p.created_at desc limit 8) a
        union all select * from (
          select jsonb_build_object('k', 'recipe', 'at', r.created_at, 'who', p.display_name, 'what', r.title, 'id', r.id) from public.recipes_public r join public.profiles p on p.id = r.author_id order by r.created_at desc limit 8) b
        union all select * from (
          select jsonb_build_object('k', 'report', 'at', x.created_at, 'who', p.display_name, 'what', x.reason, 'id', x.id) from public.reports x join public.profiles p on p.id = x.reported_id order by x.created_at desc limit 5) c
      ) u)
  ) into r;
  return r;
end $$;

-- public.admin_user_detail (da 019_admin_pro.sql): esclude le copie private
create or replace function public.admin_user_detail(uid uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r jsonb;
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  select jsonb_build_object(
    'id', p.id, 'name', p.display_name, 'handle', p.handle, 'email', u.email, 'avatar', p.avatar_url, 'type', p.account_type, 'title', p.pro_title,
    'verified', p.pro_verified, 'suspended', p.suspended, 'admin', p.is_admin, 'private', p.is_private,
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
    'reports', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (select x.id, x.reason, x.details, x.status, x.created_at, x.content_type from public.reports x where x.reported_id = p.id order by x.created_at desc limit 10) t)
  ) into r
  from public.profiles p join auth.users u on u.id = p.id where p.id = uid;
  return r;
end $$;

-- public.admin_recipe_detail (da 019_admin_pro.sql): esclude le copie private
create or replace function public.admin_recipe_detail(rid bigint) returns jsonb
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
  from public.recipes_public x join public.profiles p on p.id = x.author_id where x.id = rid;
  return r;
end $$;

