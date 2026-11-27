-- Scadenza automatica delle richieste (ogni minuto). Già applicata su Supabase.
create or replace function private.richieste_scadenza() returns int
language plpgsql security definer set search_path = '' as $$
declare n int := 0; r record;
begin
  for r in
    select q.id, q.cliente_id, q.stato, b.owner_id
      from public.richieste_ritiro q join public.botteghe b on b.id = q.bottega_id
     where q.stato in ('inviata','vista','proposta') and q.scade_at <= now()
     order by q.scade_at for update of q skip locked
  loop
    update public.richieste_ritiro set stato = 'scaduta', updated_at = now() where id = r.id;
    if r.stato = 'proposta' then
      perform private.richiesta_notifica(r.owner_id, r.cliente_id, 'richiesta_scaduta', r.id);
    else
      perform private.richiesta_notifica(r.cliente_id, r.owner_id, 'richiesta_scaduta', r.id);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

select cron.schedule('richieste-scadenza', '* * * * *', 'select private.richieste_scadenza()');
