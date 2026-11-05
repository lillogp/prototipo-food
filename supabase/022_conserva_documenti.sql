-- I documenti approvati restano consultabili nel profilo del nutrizionista; quelli rifiutati si cancellano. L'admin puo' eliminarli quando vuole.
create or replace function public.admin_review_pro(target uuid, approve boolean, reason text) returns text
language plpgsql security definer set search_path = '' as $$
declare old text;
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  if not exists (select 1 from public.profiles where id = target and account_type = 'pro') then raise exception 'nutrizionista non trovato'; end if;
  if not approve and not exists (select 1 from public.pro_verifications where user_id = target) then raise exception 'nessuna richiesta'; end if;
  update public.profiles set pro_verified = approve where id = target;
  select doc_path into old from public.pro_verifications where user_id = target;
  if approve then
    update public.pro_verifications set status = 'approved', reject_reason = null, reviewed_at = now() where user_id = target;
    return null;
  end if;
  update public.pro_verifications set status = 'rejected', reject_reason = left(reason, 300), reviewed_at = now(), doc_path = null where user_id = target;
  return old;
end $$;

create function public.admin_delete_pro_doc(target uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare old text;
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  select doc_path into old from public.pro_verifications where user_id = target;
  update public.pro_verifications set doc_path = null where user_id = target;
  return old;
end $$;
revoke execute on function public.admin_delete_pro_doc(uuid) from public, anon;
grant execute on function public.admin_delete_pro_doc(uuid) to authenticated;
