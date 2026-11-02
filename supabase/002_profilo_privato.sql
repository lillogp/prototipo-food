-- Profilo privato (come Instagram): il nome compare nella ricerca, i contenuti solo a chi è accettato.
alter table public.profiles add column is_private boolean not null default false;
grant update (is_private) on public.profiles to authenticated;

alter table public.follows add column status text not null default 'accepted' check (status in ('pending','accepted'));
drop policy "follow visibili" on public.follows;
drop policy "seguo" on public.follows;
drop policy "smetto di seguire" on public.follows;
create policy "vedo i miei follow" on public.follows for select to authenticated
  using ((select auth.uid()) in (follower_id, followed_id));
create policy "seguo o richiedo" on public.follows for insert to authenticated
  with check ((select auth.uid()) = follower_id
    and status = (case when exists (select 1 from public.profiles p where p.id = followed_id and p.is_private) then 'pending' else 'accepted' end));
create policy "accetto una richiesta" on public.follows for update to authenticated
  using ((select auth.uid()) = followed_id) with check ((select auth.uid()) = followed_id and status = 'accepted');
revoke update on public.follows from authenticated;
grant update (status) on public.follows to authenticated;
create policy "tolgo un follow o rifiuto" on public.follows for delete to authenticated
  using ((select auth.uid()) in (follower_id, followed_id));

drop policy "ricette visibili agli utenti" on public.recipes;
create policy "ricette visibili" on public.recipes for select to authenticated using (
  (select auth.uid()) = author_id
  or exists (select 1 from public.profiles p where p.id = author_id and not p.is_private)
  or exists (select 1 from public.follows f where f.follower_id = (select auth.uid()) and f.followed_id = author_id and f.status = 'accepted'));

-- Chi accetta un invito da un nutrizionista diventa privato di default (modificabile).
create or replace function public.accept_invite(code text) returns bigint
language plpgsql security definer set search_path = '' as $$
declare l public.client_links;
begin
  if (select auth.uid()) is null then raise exception 'non autenticato'; end if;
  select * into l from public.client_links where invite_code = code and status = 'pending' and client_id is null for update;
  if not found then raise exception 'invito non valido'; end if;
  if l.pro_id = (select auth.uid()) then raise exception 'non puoi accettare il tuo invito'; end if;
  update public.client_links set client_id = (select auth.uid()), status = 'active' where id = l.id;
  update public.profiles set is_private = true where id = (select auth.uid()) and account_type = 'user';
  return l.id;
end $$;
