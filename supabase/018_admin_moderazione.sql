-- Pannello admin: statistiche, utenti, piatti, storie, commenti, segnalazioni di contenuti.

-- Segnalazioni di un contenuto (oltre che di una persona)
alter table public.reports add column content_type text check (content_type in ('recipe','comment','story')), add column content_id text;
drop index if exists public.reports_reporter_id_reported_id_idx;
create unique index on public.reports (reporter_id, reported_id, coalesce(content_type, ''), coalesce(content_id, '')) where status = 'open';

-- Ogni funzione controlla is_admin() e non e' richiamabile da altri.
create function public.admin_dashboard() returns table (users bigint, new_users_7d bigint, pros bigint, pros_verified bigint, recipes bigint, stories_active bigint, open_reports bigint)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  return query select
    (select count(*) from public.profiles),
    (select count(*) from public.profiles where created_at > now() - interval '7 days'),
    (select count(*) from public.profiles where account_type = 'pro'),
    (select count(*) from public.profiles where account_type = 'pro' and pro_verified),
    (select count(*) from public.recipes),
    (select count(*) from public.stories where expires_at > now()),
    (select count(*) from public.reports where status = 'open');
end $$;

create function public.admin_users(q text, lim int default 50, off int default 0) returns table (user_id uuid, name text, handle text, email text, account_type text, pro_verified boolean, suspended boolean, is_admin boolean, created_at timestamptz, recipes bigint, terms_version text)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  return query select p.id, p.display_name, p.handle, u.email::text, p.account_type, p.pro_verified, p.suspended, p.is_admin, p.created_at,
      (select count(*) from public.recipes r where r.author_id = p.id), (u.raw_user_meta_data ->> 'terms_version')
    from public.profiles p join auth.users u on u.id = p.id
    where coalesce(q, '') = '' or p.display_name ilike '%' || q || '%' or p.handle ilike '%' || q || '%' or u.email ilike '%' || q || '%'
    order by p.created_at desc limit least(coalesce(lim, 50), 200) offset greatest(coalesce(off, 0), 0);
end $$;

create function public.admin_recipes(lim int default 40, off int default 0) returns table (recipe_id bigint, title text, author_id uuid, author_name text, media_url text, created_at timestamptz, open_reports bigint)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  return query select r.id, r.title, r.author_id, p.display_name, r.media_url, r.created_at,
      (select count(*) from public.reports x where x.content_type = 'recipe' and x.content_id = r.id::text and x.status = 'open')
    from public.recipes r join public.profiles p on p.id = r.author_id
    order by r.created_at desc limit least(coalesce(lim, 40), 100) offset greatest(coalesce(off, 0), 0);
end $$;

create function public.admin_delete_recipe(rid bigint) returns text
language plpgsql security definer set search_path = '' as $$
declare m text;
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  delete from public.recipes where id = rid returning media_url into m;
  update public.reports set status = 'reviewed' where content_type = 'recipe' and content_id = rid::text and status = 'open';
  return m;
end $$;

create function public.admin_stories() returns table (story_id uuid, author_id uuid, author_name text, media_url text, media_path text, caption text, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  return query select s.id, s.author_id, p.display_name, s.media_url, s.media_path, s.caption, s.created_at
    from public.stories s join public.profiles p on p.id = s.author_id where s.expires_at > now() order by s.created_at desc limit 100;
end $$;

create function public.admin_delete_story(sid uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare m text;
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  delete from public.stories where id = sid returning media_path into m;
  return m;
end $$;

create function public.admin_comments(lim int default 50) returns table (comment_id bigint, body text, author_id uuid, author_name text, recipe_id bigint, recipe_title text, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  return query select c.id, c.body, c.author_id, p.display_name, c.recipe_id, r.title, c.created_at
    from public.comments c join public.profiles p on p.id = c.author_id left join public.recipes r on r.id = c.recipe_id
    order by c.created_at desc limit least(coalesce(lim, 50), 100);
end $$;

create function public.admin_delete_comment(cid bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  delete from public.comments where id = cid;
end $$;

-- Eliminazione di un account da parte dell'admin (non di un altro admin)
create function public.admin_delete_user(target uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  if exists (select 1 from public.profiles where id = target and is_admin) then raise exception 'non autorizzato'; end if;
  delete from auth.users where id = target;
end $$;

-- Segnalazioni con il contenuto segnalato
create function public.admin_reports2(st text) returns table (report_id bigint, reporter_id uuid, reporter_name text, reported_id uuid, reported_name text,
  reported_email text, reported_suspended boolean, reason text, details text, conv_id bigint, status text, created_at timestamptz,
  content_type text, content_id text, content_title text, content_media text)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  return query select r.id, r.reporter_id, rp.display_name, r.reported_id, rd.display_name, u.email::text, rd.suspended,
      r.reason, r.details, r.conv_id, r.status, r.created_at, r.content_type, r.content_id,
      (case when r.content_type = 'recipe' then (select x.title from public.recipes x where x.id::text = r.content_id) end),
      (case when r.content_type = 'recipe' then (select x.media_url from public.recipes x where x.id::text = r.content_id) end)
    from public.reports r
    join public.profiles rp on rp.id = r.reporter_id
    join public.profiles rd on rd.id = r.reported_id
    join auth.users u on u.id = r.reported_id
    where (st = 'open' and r.status = 'open') or (st <> 'open' and r.status <> 'open')
    order by r.created_at desc limit 100;
end $$;

-- Gli admin possono togliere i file dallo storage (foto di contenuti rimossi)
create policy "admin elimina file" on storage.objects for delete to authenticated
  using (bucket_id = 'media' and private.is_admin());

revoke execute on function public.admin_dashboard(), public.admin_users(text, int, int), public.admin_recipes(int, int), public.admin_delete_recipe(bigint),
  public.admin_stories(), public.admin_delete_story(uuid), public.admin_comments(int), public.admin_delete_comment(bigint), public.admin_delete_user(uuid),
  public.admin_reports2(text) from public, anon;
grant execute on function public.admin_dashboard(), public.admin_users(text, int, int), public.admin_recipes(int, int), public.admin_delete_recipe(bigint),
  public.admin_stories(), public.admin_delete_story(uuid), public.admin_comments(int), public.admin_delete_comment(bigint), public.admin_delete_user(uuid),
  public.admin_reports2(text) to authenticated;
