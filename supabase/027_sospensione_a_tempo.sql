-- Sospensione a tempo: l'admin sceglie ore, giorni o mesi (oppure nessuna scadenza). Un account sospeso non puo' accedere:
-- il blocco e' sull'accesso (auth.users.banned_until), che scade da solo alla data indicata.
alter table public.profiles add column suspended_until timestamptz;

create function public.admin_suspend_user(target uuid, until_at timestamptz, reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare rs text := left(btrim(coalesce(reason, '')), 200);
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  if target = (select auth.uid()) then raise exception 'non puoi sospendere te stesso'; end if;
  if until_at is not null and (until_at <= now() or until_at > now() + interval '5 years') then raise exception 'data non valida'; end if;
  update public.profiles set suspended = true, suspended_until = until_at where id = target;
  update auth.users set banned_until = coalesce(until_at, now() + interval '100 years') where id = target;
  insert into public.admin_warnings (user_id, admin_id, reason, body)
  values (target, (select auth.uid()), 'Sospensione',
    coalesce(nullif(rs, ''), 'Account sospeso') || case when until_at is null then ' (a tempo indeterminato)' else ' (fino al ' || to_char(until_at at time zone 'Europe/Rome', 'DD/MM/YYYY HH24:MI') || ')' end);
end $$;
revoke execute on function public.admin_suspend_user(uuid, timestamptz, text) from public, anon;
grant execute on function public.admin_suspend_user(uuid, timestamptz, text) to authenticated;

-- Riattivazione manuale: toglie anche la scadenza.
create or replace function public.admin_set_suspended(target uuid, flag boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  if target = (select auth.uid()) then raise exception 'non puoi sospendere te stesso'; end if;
  update public.profiles set suspended = flag, suspended_until = null where id = target;
  update auth.users set banned_until = case when flag then now() + interval '100 years' else null end where id = target;
end $$;

-- Un account con sospensione scaduta torna visibile subito, anche prima del controllo periodico.
drop policy "profili visibili" on public.profiles;
create policy "profili visibili" on public.profiles for select to authenticated using (
  private.is_admin()
  or (not private.blocked_pair(id) and (not suspended or (suspended_until is not null and suspended_until <= now()) or id = (select auth.uid()))));

-- Riattivazione automatica delle sospensioni scadute.
create function private.sweep_suspensions() returns void
language sql security definer set search_path = '' as $$
  update public.profiles set suspended = false, suspended_until = null where suspended and suspended_until is not null and suspended_until <= now();
$$;
do $$ begin
  create extension if not exists pg_cron;
  perform cron.schedule('sweep-suspensions', '*/5 * * * *', 'select private.sweep_suspensions()');
exception when others then raise notice 'pg_cron non disponibile: %', sqlerrm;
end $$;

create or replace function public.admin_user_detail(uid uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r jsonb;
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  select jsonb_build_object(
    'id', p.id, 'name', p.display_name, 'handle', p.handle, 'email', u.email, 'avatar', p.avatar_url, 'type', p.account_type, 'title', p.pro_title,
    'verified', p.pro_verified, 'suspended', p.suspended, 'suspended_until', p.suspended_until, 'admin', p.is_admin, 'private', p.is_private, 'bio', p.bio,
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
