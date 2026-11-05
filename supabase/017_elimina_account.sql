-- Eliminazione dell'account da parte dell'utente (GDPR / requisito degli store).
-- Cancella l'utente in auth.users: profilo e contenuti seguono con "on delete cascade".
create function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
declare me uuid := (select auth.uid());
begin
  if me is null then raise exception 'non autenticato'; end if;
  if exists (select 1 from public.profiles where id = me and is_admin) then raise exception 'un amministratore non puo'' eliminare cosi'' il proprio account'; end if;
  delete from auth.users where id = me;
end $$;
revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
