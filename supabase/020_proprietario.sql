-- Solo il proprietario puo' nominare o togliere gli amministratori.
alter table public.profiles add column is_owner boolean not null default false;
-- (nessun permesso di UPDATE per gli utenti su questa colonna: resta modificabile solo da migrazione)
update public.profiles set is_owner = true, is_admin = true where id = (select id from auth.users where email = 'teo91bongi@gmail.com');

create function private.is_owner() returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select p.is_owner and p.is_admin from public.profiles p where p.id = (select auth.uid())), false);
$$;
revoke execute on function private.is_owner() from public, anon;
grant execute on function private.is_owner() to authenticated;

create function public.admin_roles() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  return jsonb_build_object('me_owner', private.is_owner(), 'owner_ids', (select coalesce(jsonb_agg(id), '[]'::jsonb) from public.profiles where is_owner));
end $$;

create function public.admin_set_admin(target uuid, flag boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_owner() then raise exception 'non autorizzato'; end if;
  if target = (select auth.uid()) then raise exception 'non autorizzato'; end if;
  if exists (select 1 from public.profiles where id = target and is_owner) then raise exception 'non autorizzato'; end if;
  if flag and exists (select 1 from public.profiles where id = target and suspended) then raise exception 'account sospeso'; end if;
  update public.profiles set is_admin = flag where id = target;
  if not found then raise exception 'utente non trovato'; end if;
end $$;

revoke execute on function public.admin_roles(), public.admin_set_admin(uuid, boolean) from public, anon;
grant execute on function public.admin_roles(), public.admin_set_admin(uuid, boolean) to authenticated;
