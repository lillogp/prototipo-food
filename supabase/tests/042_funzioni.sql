-- Test funzioni richieste: una sola chiamata; eccezione se qualcosa non va, altrimenti ritorna 'ok'. Tutto in rollback.
begin;
do $$
declare
  c1 uuid := '5d13c3ad-a361-4b73-ae44-0cd81df22400';
  c2 uuid := '4837df96-894c-4c5b-838e-d9393b6f756a';
  own uuid := 'e692ed19-ea75-42bf-b7e5-f79bae626125';
  nocan uuid := 'f26dc4db-30ae-4022-9b86-45475b8bc527';
  d_thu date := current_date + (((4 - extract(isodow from current_date)::int) + 6) % 7 + 1);
  d_sun date := current_date + (((7 - extract(isodow from current_date)::int) + 6) % 7 + 1);
  rid uuid; rid2 uuid; rid3 uuid; rid4 uuid; rid5 uuid; r record; n int; i int; t timestamptz;
  righe jsonb := '[{"prodotto_id":1,"quantita":2},{"prodotto_id":2,"quantita":0.5}]';
begin
  execute 'set local role authenticated';

  -- non autorizzati
  perform set_config('request.jwt.claims', json_build_object('sub', nocan, 'role', 'authenticated')::text, true);
  begin perform public.richiesta_invia(1, (d_thu + time '10:00') at time zone 'Europe/Rome', righe, null); raise exception 'FAIL senza can_abuela';
  exception when others then if sqlerrm <> 'non_autorizzato' then raise exception 'FAIL senza can_abuela: %', sqlerrm; end if; end;

  perform set_config('request.jwt.claims', json_build_object('sub', c1, 'role', 'authenticated')::text, true);
  -- invii non validi
  begin perform public.richiesta_invia(999, (d_thu + time '10:00') at time zone 'Europe/Rome', righe, null); raise exception 'FAIL bottega inesistente';
  exception when others then if sqlerrm <> 'bottega_non_prenotabile' then raise exception 'FAIL bottega inesistente: %', sqlerrm; end if; end;
  begin perform public.richiesta_invia(1, now() - interval '1 hour', righe, null); raise exception 'FAIL passato';
  exception when others then if sqlerrm <> 'ritiro_non_valido' then raise exception 'FAIL passato: %', sqlerrm; end if; end;
  begin perform public.richiesta_invia(1, (d_thu + 15 + time '10:00') at time zone 'Europe/Rome', righe, null); raise exception 'FAIL oltre 14 giorni';
  exception when others then if sqlerrm <> 'ritiro_non_valido' then raise exception 'FAIL oltre 14 giorni: %', sqlerrm; end if; end;
  begin perform public.richiesta_invia(1, (d_thu + time '10:15') at time zone 'Europe/Rome', righe, null); raise exception 'FAIL minuti fuori griglia';
  exception when others then if sqlerrm <> 'ritiro_non_valido' then raise exception 'FAIL minuti fuori griglia: %', sqlerrm; end if; end;
  begin perform public.richiesta_invia(1, (d_sun + time '10:00') at time zone 'Europe/Rome', righe, null); raise exception 'FAIL domenica';
  exception when others then if sqlerrm <> 'ritiro_chiuso' then raise exception 'FAIL domenica: %', sqlerrm; end if; end;
  begin perform public.richiesta_invia(1, (d_thu + time '03:00') at time zone 'Europe/Rome', righe, null); raise exception 'FAIL notte';
  exception when others then if sqlerrm <> 'ritiro_chiuso' then raise exception 'FAIL notte: %', sqlerrm; end if; end;
  begin perform public.richiesta_invia(1, (d_thu + time '10:00') at time zone 'Europe/Rome', '[{"prodotto_id":999,"quantita":1}]', null); raise exception 'FAIL prodotto inesistente';
  exception when others then if sqlerrm <> 'prodotti_non_validi' then raise exception 'FAIL prodotto inesistente: %', sqlerrm; end if; end;
  begin perform public.richiesta_invia(1, (d_thu + time '10:00') at time zone 'Europe/Rome', '[]', null); raise exception 'FAIL righe vuote';
  exception when others then if sqlerrm <> 'prodotti_non_validi' then raise exception 'FAIL righe vuote: %', sqlerrm; end if; end;

  -- chiusura straordinaria
  perform set_config('request.jwt.claims', json_build_object('sub', own, 'role', 'authenticated')::text, true);
  update public.botteghe set chiusure = jsonb_build_array(jsonb_build_object('dal', d_thu::text, 'al', d_thu::text)) where id = 1;
  perform set_config('request.jwt.claims', json_build_object('sub', c1, 'role', 'authenticated')::text, true);
  begin perform public.richiesta_invia(1, (d_thu + time '10:00') at time zone 'Europe/Rome', righe, null); raise exception 'FAIL chiusura';
  exception when others then if sqlerrm <> 'ritiro_chiuso' then raise exception 'FAIL chiusura: %', sqlerrm; end if; end;
  perform set_config('request.jwt.claims', json_build_object('sub', own, 'role', 'authenticated')::text, true);
  update public.botteghe set chiusure = '[]'::jsonb where id = 1;
  perform set_config('request.jwt.claims', json_build_object('sub', c1, 'role', 'authenticated')::text, true);

  -- invio valido
  rid := public.richiesta_invia(1, (d_thu + time '10:00') at time zone 'Europe/Rome', righe, 'senza ossa');
  select * into r from public.richieste_ritiro where id = rid;
  if r.stato <> 'inviata' then raise exception 'FAIL stato iniziale %', r.stato; end if;
  if r.scade_at > now() + interval '30 minutes 2 seconds' or r.scade_at < now() + interval '29 minutes' then raise exception 'FAIL scade_at %', r.scade_at; end if;
  select count(*) into n from public.richiesta_righe where richiesta_id = rid;
  if n <> 2 then raise exception 'FAIL righe %', n; end if;
  execute 'reset role';
  select count(*) into n from public.notifications where user_id = own and actor_id = c1 and type = 'richiesta_nuova' and ref->>'richiesta_id' = rid::text;
  if n <> 1 then raise exception 'FAIL notifica nuova %', n; end if;
  execute 'set local role authenticated';

  -- il prezzo copiato non cambia
  perform set_config('request.jwt.claims', json_build_object('sub', own, 'role', 'authenticated')::text, true);
  update public.prodotti set prezzo_cent = 9999 where id = 1;
  perform set_config('request.jwt.claims', json_build_object('sub', c1, 'role', 'authenticated')::text, true);
  if (select prezzo_cent from public.richiesta_righe where richiesta_id = rid and prodotto_id = 1) <> 1150 then raise exception 'FAIL prezzo copiato'; end if;

  -- altri non possono rispondere
  perform set_config('request.jwt.claims', json_build_object('sub', c2, 'role', 'authenticated')::text, true);
  begin perform public.richiesta_rispondi(rid, 'conferma'); raise exception 'FAIL risposta di un estraneo';
  exception when others then if sqlerrm <> 'non_autorizzato' then raise exception 'FAIL risposta di un estraneo: %', sqlerrm; end if; end;

  -- proposta
  perform set_config('request.jwt.claims', json_build_object('sub', own, 'role', 'authenticated')::text, true);
  begin perform public.richiesta_rispondi(rid, 'proponi', null, (d_sun + time '10:00') at time zone 'Europe/Rome'); raise exception 'FAIL proposta domenica';
  exception when others then if sqlerrm <> 'ritiro_chiuso' then raise exception 'FAIL proposta domenica: %', sqlerrm; end if; end;
  perform public.richiesta_vista(rid);
  if (select stato from public.richieste_ritiro where id = rid) <> 'vista' then raise exception 'FAIL vista'; end if;
  t := (d_thu + time '11:00') at time zone 'Europe/Rome';
  perform public.richiesta_rispondi(rid, 'proponi', null, t);
  select * into r from public.richieste_ritiro where id = rid;
  if r.stato <> 'proposta' or r.ritiro_proposto_at <> t then raise exception 'FAIL proposta %', r.stato; end if;
  if r.scade_at > now() + interval '30 minutes 2 seconds' then raise exception 'FAIL scadenza proposta'; end if;

  -- il cliente accetta
  perform set_config('request.jwt.claims', json_build_object('sub', c1, 'role', 'authenticated')::text, true);
  perform public.richiesta_risposta_cliente(rid, true);
  select * into r from public.richieste_ritiro where id = rid;
  if r.stato <> 'confermata' or r.ritiro_at <> t then raise exception 'FAIL accettazione proposta %', r.stato; end if;

  -- esito prima dell'orario: no; dopo: sì
  perform set_config('request.jwt.claims', json_build_object('sub', own, 'role', 'authenticated')::text, true);
  begin perform public.richiesta_esito(rid, 'ritirata'); raise exception 'FAIL esito anticipato';
  exception when others then if sqlerrm <> 'stato_non_valido' then raise exception 'FAIL esito anticipato: %', sqlerrm; end if; end;
  execute 'reset role'; update public.richieste_ritiro set ritiro_at = now() - interval '1 hour' where id = rid; execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', own, 'role', 'authenticated')::text, true);
  perform public.richiesta_esito(rid, 'ritirata');
  if (select stato from public.richieste_ritiro where id = rid) <> 'ritirata' then raise exception 'FAIL esito'; end if;

  -- conferma e annullo
  perform set_config('request.jwt.claims', json_build_object('sub', c1, 'role', 'authenticated')::text, true);
  rid2 := public.richiesta_invia(1, (d_thu + time '08:00') at time zone 'Europe/Rome', righe, null);
  perform set_config('request.jwt.claims', json_build_object('sub', own, 'role', 'authenticated')::text, true);
  perform public.richiesta_rispondi(rid2, 'conferma');
  perform set_config('request.jwt.claims', json_build_object('sub', c1, 'role', 'authenticated')::text, true);
  perform public.richiesta_annulla(rid2);
  begin perform public.richiesta_annulla(rid2); raise exception 'FAIL doppio annullo';
  exception when others then if sqlerrm <> 'stato_non_valido' then raise exception 'FAIL doppio annullo: %', sqlerrm; end if; end;

  -- rifiuto con motivo
  rid3 := public.richiesta_invia(1, (d_thu + time '08:30') at time zone 'Europe/Rome', righe, null);
  perform set_config('request.jwt.claims', json_build_object('sub', own, 'role', 'authenticated')::text, true);
  perform public.richiesta_rispondi(rid3, 'rifiuta', 'finito il macinato');
  if (select motivo_rifiuto from public.richieste_ritiro where id = rid3) <> 'finito il macinato' then raise exception 'FAIL motivo'; end if;

  -- corsa con la scadenza
  perform set_config('request.jwt.claims', json_build_object('sub', c1, 'role', 'authenticated')::text, true);
  rid4 := public.richiesta_invia(1, (d_thu + time '09:00') at time zone 'Europe/Rome', righe, null);
  execute 'reset role'; update public.richieste_ritiro set scade_at = now() - interval '1 minute' where id = rid4; execute 'set local role authenticated';
  perform set_config('request.jwt.claims', json_build_object('sub', own, 'role', 'authenticated')::text, true);
  begin perform public.richiesta_rispondi(rid4, 'conferma'); raise exception 'FAIL risposta dopo scadenza';
  exception when others then if sqlerrm <> 'richiesta_scaduta' then raise exception 'FAIL risposta dopo scadenza: %', sqlerrm; end if; end;

  -- proposta rifiutata dal cliente
  perform set_config('request.jwt.claims', json_build_object('sub', c1, 'role', 'authenticated')::text, true);
  rid5 := public.richiesta_invia(1, (d_thu + time '09:30') at time zone 'Europe/Rome', righe, null);
  perform set_config('request.jwt.claims', json_build_object('sub', own, 'role', 'authenticated')::text, true);
  perform public.richiesta_rispondi(rid5, 'proponi', null, (d_thu + time '12:00') at time zone 'Europe/Rome');
  perform set_config('request.jwt.claims', json_build_object('sub', c1, 'role', 'authenticated')::text, true);
  perform public.richiesta_risposta_cliente(rid5, false);
  if (select stato from public.richieste_ritiro where id = rid5) <> 'annullata' then raise exception 'FAIL proposta rifiutata'; end if;

  -- tetto di 6 richieste aperte (c2)
  perform set_config('request.jwt.claims', json_build_object('sub', c2, 'role', 'authenticated')::text, true);
  for i in 0..5 loop
    perform public.richiesta_invia(1, (d_thu + time '07:30' + (i * interval '30 minutes')) at time zone 'Europe/Rome', righe, null);
  end loop;
  begin perform public.richiesta_invia(1, (d_thu + time '11:00') at time zone 'Europe/Rome', righe, null); raise exception 'FAIL tetto';
  exception when others then if sqlerrm <> 'troppe_richieste' then raise exception 'FAIL tetto: %', sqlerrm; end if; end;

  execute 'reset role';
end $$;
select 'ok' as esito;
rollback;
