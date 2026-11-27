-- Test schema richieste: eseguire in una sola chiamata; fallisce con eccezione, altrimenti ritorna 'ok'.
begin;
insert into public.richieste_ritiro (id, bottega_id, cliente_id, stato, ritiro_at, scade_at)
values ('00000000-0000-0000-0000-0000000000a1', 1, '5d13c3ad-a361-4b73-ae44-0cd81df22400', 'inviata', now() + interval '1 day', now() + interval '30 minutes');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"5d13c3ad-a361-4b73-ae44-0cd81df22400","role":"authenticated"}', true);
do $$
declare n int;
begin
  begin update public.profiles set account_type = 'commerciante' where id = '5d13c3ad-a361-4b73-ae44-0cd81df22400'; get diagnostics n = row_count;
    if n > 0 then raise exception 'FAIL: account_type modificabile da utente'; end if;
  exception when insufficient_privilege then null; end;
  begin insert into public.richieste_ritiro (bottega_id, cliente_id, stato, ritiro_at) values (1, '5d13c3ad-a361-4b73-ae44-0cd81df22400', 'inviata', now() + interval '1 day');
    raise exception 'FAIL: insert diretto consentito';
  exception when insufficient_privilege then null; end;
  begin update public.richieste_ritiro set stato = 'confermata'; get diagnostics n = row_count;
    if n > 0 then raise exception 'FAIL: update diretto consentito'; end if;
  exception when insufficient_privilege then null; end;
  select count(*) into n from public.richieste_ritiro;
  if n <> 1 then raise exception 'FAIL: il cliente dovrebbe vedere 1 richiesta, ne vede %', n; end if;
end $$;

select set_config('request.jwt.claims', '{"sub":"4837df96-894c-4c5b-838e-d9393b6f756a","role":"authenticated"}', true);
do $$ declare n int; begin
  select count(*) into n from public.richieste_ritiro;
  if n <> 0 then raise exception 'FAIL: un altro cliente vede % richieste', n; end if;
end $$;

select set_config('request.jwt.claims', '{"sub":"e692ed19-ea75-42bf-b7e5-f79bae626125","role":"authenticated"}', true);
do $$ declare n int; begin
  select count(*) into n from public.richieste_ritiro;
  if n <> 1 then raise exception 'FAIL: il titolare dovrebbe vedere 1 richiesta, ne vede %', n; end if;
  update public.botteghe set chiusure = '[{"dal":"2026-12-24","al":"2026-12-26"}]'::jsonb where id = 1;
  if (select chiusure from public.botteghe where id = 1) is distinct from '[{"dal":"2026-12-24","al":"2026-12-26"}]'::jsonb then raise exception 'FAIL: il titolare non riesce a salvare le chiusure'; end if;
end $$;
select 'ok' as esito;
rollback;
