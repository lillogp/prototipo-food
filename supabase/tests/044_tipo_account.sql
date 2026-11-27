-- Prova (si annulla da sola): solo un amministratore cambia il tipo; 'pro' e valori strani rifiutati.
begin;
do $$
declare adm uuid; usr uuid; pro uuid; r text;
begin
  select id into adm from public.profiles where is_admin limit 1;
  select p.id into usr from public.profiles p where not coalesce(p.is_admin, false) and p.account_type = 'user' limit 1;
  select id into pro from public.profiles where account_type = 'pro' limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', usr, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.admin_imposta_tipo_account(usr, 'commerciante'); raise exception 'FAIL: un utente normale non deve poterlo fare';
  exception when others then if sqlerrm <> 'non autorizzato' then raise; end if; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.admin_imposta_tipo_account(usr, 'commerciante');
  reset role;
  select account_type into r from public.profiles where id = usr;
  if r <> 'commerciante' then raise exception 'FAIL: tipo non cambiato (%)', r; end if;
  set local role authenticated;
  begin perform public.admin_imposta_tipo_account(usr, 'pro'); raise exception 'FAIL: pro non ammesso';
  exception when others then if sqlerrm <> 'tipo non valido' then raise; end if; end;
  if pro is not null then
    begin perform public.admin_imposta_tipo_account(pro, 'user'); raise exception 'FAIL: la nutrizionista non si tocca';
    exception when others then if sqlerrm <> 'account nutrizionista' then raise; end if; end;
  end if;
  perform public.admin_imposta_tipo_account(usr, 'user');
  reset role;
  select account_type into r from public.profiles where id = usr;
  if r <> 'user' then raise exception 'FAIL: non tornato utente'; end if;
end $$;
select 'ok' as esito;
rollback;
