-- valutazioni_stato: aggiunge l'id della valutazione ricevuta (serve per segnalarla).
drop function if exists public.valutazioni_stato(uuid[]);
create function public.valutazioni_stato(p_ids uuid[]) returns table (richiesta_id uuid, data boolean, ricevuto_id bigint, ricevuto_voto smallint, ricevuto_commento text)
language sql stable security definer set search_path = '' as $$
  select r.id,
    exists (select 1 from public.valutazioni v where v.richiesta_id = r.id and v.autore_id = (select auth.uid())),
    x.id, x.voto, x.commento
  from public.richieste_ritiro r
  left join lateral (select v.id, v.voto, v.commento from public.valutazioni v
    where v.richiesta_id = r.id and v.destinatario_id = (select auth.uid()) and not v.nascosta and private.val_visibile(v.richiesta_id, v.verso, v.created_at) limit 1) x on true
  where r.id = any (p_ids)
    and (r.cliente_id = (select auth.uid()) or exists (select 1 from public.botteghe b where b.id = r.bottega_id and b.owner_id = (select auth.uid())))
$$;
revoke execute on function public.valutazioni_stato(uuid[]) from public, anon;
grant execute on function public.valutazioni_stato(uuid[]) to authenticated;
