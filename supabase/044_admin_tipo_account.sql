-- Tipo di account assegnato dall'amministratore: utente normale o commerciante (chi gestisce una bottega).
-- Le nutrizioniste ('pro') hanno un percorso a parte (verifica): qui non si toccano né si creano.
create or replace function public.admin_imposta_tipo_account(target uuid, tipo text) returns void
language plpgsql security definer set search_path = '' as $$
declare cur text;
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  if tipo not in ('user', 'commerciante') then raise exception 'tipo non valido'; end if;
  select account_type into cur from public.profiles where id = target;
  if not found then raise exception 'utente non trovato'; end if;
  if cur = 'pro' then raise exception 'account nutrizionista'; end if;
  update public.profiles set account_type = tipo where id = target;
end $$;
revoke execute on function public.admin_imposta_tipo_account(uuid, text) from public, anon;
grant execute on function public.admin_imposta_tipo_account(uuid, text) to authenticated;
