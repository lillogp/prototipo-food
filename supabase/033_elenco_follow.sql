-- Elenco seguaci / seguiti di un profilo, visibile nel profilo altrui.
-- Profilo privato: l'elenco lo vede solo il proprietario o chi lo segue (richiesta accettata).
-- Non mostra persone che hai bloccato.
create or replace function public.follow_list(p_user uuid, p_kind text)
returns table (uid uuid)
language sql stable security definer set search_path = '' as $$
  select case when p_kind = 'followers' then f.follower_id else f.followed_id end
  from public.follows f
  where f.status = 'accepted'
    and p_kind in ('followers', 'following')
    and (case when p_kind = 'followers' then f.followed_id else f.follower_id end) = p_user
    and (
      p_user = (select auth.uid())
      or not coalesce((select p.is_private from public.profiles p where p.id = p_user), false)
      or exists (select 1 from public.follows x where x.follower_id = (select auth.uid()) and x.followed_id = p_user and x.status = 'accepted')
    )
    and not exists (
      select 1 from public.blocks b
      where b.blocker_id = (select auth.uid())
        and b.blocked_id = (case when p_kind = 'followers' then f.follower_id else f.followed_id end)
    );
$$;
revoke all on function public.follow_list(uuid, text) from public, anon;
grant execute on function public.follow_list(uuid, text) to authenticated;
