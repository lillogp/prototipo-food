-- Test scadenza automatica: ritorna 'ok' o solleva eccezione. Tutto in rollback.
begin;
insert into public.richieste_ritiro (id, bottega_id, cliente_id, stato, ritiro_at, scade_at) values
 ('00000000-0000-0000-0000-0000000000b1', 1, '5d13c3ad-a361-4b73-ae44-0cd81df22400', 'inviata', now() + interval '1 day', now() - interval '1 minute'),
 ('00000000-0000-0000-0000-0000000000b2', 1, '5d13c3ad-a361-4b73-ae44-0cd81df22400', 'vista', now() + interval '1 day', now() + interval '10 minutes'),
 ('00000000-0000-0000-0000-0000000000b3', 1, '5d13c3ad-a361-4b73-ae44-0cd81df22400', 'proposta', now() + interval '1 day', now() - interval '1 minute'),
 ('00000000-0000-0000-0000-0000000000b4', 1, '5d13c3ad-a361-4b73-ae44-0cd81df22400', 'confermata', now() + interval '1 day', null);
do $$
declare n int;
begin
  n := private.richieste_scadenza();
  if n <> 2 then raise exception 'FAIL scadute % invece di 2', n; end if;
  if (select string_agg(stato, ',' order by id) from public.richieste_ritiro where id::text like '00000000-0000-0000-0000-0000000000b%') <> 'scaduta,vista,scaduta,confermata' then raise exception 'FAIL stati'; end if;
  if (select count(*) from public.notifications where type = 'richiesta_scaduta' and user_id = '5d13c3ad-a361-4b73-ae44-0cd81df22400' and ref->>'richiesta_id' = '00000000-0000-0000-0000-0000000000b1') <> 1 then raise exception 'FAIL notifica al cliente'; end if;
  if (select count(*) from public.notifications where type = 'richiesta_scaduta' and user_id = 'e692ed19-ea75-42bf-b7e5-f79bae626125' and ref->>'richiesta_id' = '00000000-0000-0000-0000-0000000000b3') <> 1 then raise exception 'FAIL notifica al titolare per la proposta'; end if;
  if private.richieste_scadenza() <> 0 then raise exception 'FAIL non idempotente'; end if;
end $$;
select 'ok' as esito;
rollback;
