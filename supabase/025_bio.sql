-- Breve descrizione ("bio") del profilo, modificabile da chi la scrive.
alter table public.profiles add column bio text check (bio is null or char_length(bio) <= 200);
grant update (bio) on public.profiles to authenticated;

-- Il pannello admin mostra la descrizione per la moderazione.
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
    'reports', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (select x.id, x.reason, x.details, x.status, x.created_at, x.content_type from public.reports x where x.reported_id = p.id order by x.created_at desc limit 10) t)
  ) into r
  from public.profiles p join auth.users u on u.id = p.id where p.id = uid;
  return r;
end $$;
