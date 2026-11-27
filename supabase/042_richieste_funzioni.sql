-- Richieste di ritiro (fase 1): funzioni di transizione. Già applicata su Supabase.
-- Le richieste si scrivono solo da qui (nessuna policy di insert/update). Errori = messaggio-codice.

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check check (type = any (array[
  'follow','follow_request','follow_accepted','like','comment','comment_like','client_joined','plan','message','dm','dm_request',
  'story_like','admin_warning','secret_request','secret_accepted','tag',
  'richiesta_nuova','richiesta_confermata','richiesta_rifiutata','richiesta_proposta','richiesta_scaduta','richiesta_annullata','richiesta_accettata']));

create or replace function private.richiesta_notifica(p_user uuid, p_actor uuid, p_tipo text, p_rid uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.notifications (user_id, actor_id, type, ref) values (p_user, p_actor, p_tipo, jsonb_build_object('richiesta_id', p_rid))
$$;

-- null se l'orario di ritiro è valido per la bottega, altrimenti il codice dell'errore
create or replace function private.ritiro_errore(p_bottega bigint, p_ritiro timestamptz) returns text
language plpgsql stable security definer set search_path = '' as $$
declare b record; loc timestamp; d date; t time; chiave text; fasce text; ok boolean;
begin
  if p_ritiro is null or p_ritiro <= now() or p_ritiro > now() + make_interval(days => private.richiesta_config('max_giorni')) then return 'ritiro_non_valido'; end if;
  loc := p_ritiro at time zone 'Europe/Rome';
  if extract(minute from loc)::int % 30 <> 0 or extract(second from loc) <> 0 then return 'ritiro_non_valido'; end if;
  select orari_sett, chiusure into b from public.botteghe where id = p_bottega;
  d := loc::date; t := loc::time;
  if exists (select 1 from jsonb_array_elements(coalesce(b.chiusure, '[]'::jsonb)) c
             where c->>'dal' ~ '^\d{4}-\d\d-\d\d$' and c->>'al' ~ '^\d{4}-\d\d-\d\d$' and d between (c->>'dal')::date and (c->>'al')::date) then
    return 'ritiro_chiuso';
  end if;
  chiave := (array['lun','mar','mer','gio','ven','sab','dom'])[extract(isodow from loc)::int];
  fasce := b.orari_sett ->> chiave;
  if fasce is null then return 'ritiro_chiuso'; end if;
  select exists (select 1 from unnest(string_to_array(replace(fasce, '-', '–'), ',')) f,
                 lateral (select split_part(trim(f), '–', 1) a, split_part(trim(f), '–', 2) c) x
                 where a ~ '^\d\d:\d\d$' and c ~ '^\d\d:\d\d$' and t >= a::time and t <= c::time - interval '30 minutes') into ok;
  if not ok then return 'ritiro_chiuso'; end if;
  return null;
end $$;

create or replace function public.richiesta_invia(p_bottega bigint, p_ritiro timestamptz, p_righe jsonb, p_nota text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); b record; err text; n int; nr int; nv int; rid uuid;
begin
  if uid is null or not private.can_abuela() then raise exception 'non_autorizzato'; end if;
  select id, owner_id, attiva, ritiro, orari_sett into b from public.botteghe where id = p_bottega;
  if not found or not b.attiva or not coalesce(b.ritiro, false) or b.orari_sett is null or b.orari_sett = '{}'::jsonb then raise exception 'bottega_non_prenotabile'; end if;
  if b.owner_id = uid then raise exception 'non_autorizzato'; end if;
  select count(*) into n from public.richieste_ritiro where cliente_id = uid and (stato in ('inviata','vista','proposta') or (stato = 'confermata' and ritiro_at > now()));
  if n >= private.richiesta_config('max_aperte') then raise exception 'troppe_richieste'; end if;
  err := private.ritiro_errore(p_bottega, p_ritiro);
  if err is not null then raise exception '%', err; end if;
  begin
    if p_righe is null or jsonb_typeof(p_righe) <> 'array' or jsonb_array_length(p_righe) = 0 or jsonb_array_length(p_righe) > 30 then raise exception 'prodotti_non_validi'; end if;
    nr := jsonb_array_length(p_righe);
    select count(*), count(distinct x.prodotto_id) into nv, n
      from jsonb_to_recordset(p_righe) as x(prodotto_id bigint, quantita numeric)
      join public.prodotti p on p.id = x.prodotto_id and p.bottega_id = p_bottega and p.disponibile
      where x.quantita > 0 and x.quantita <= 100;
    if nv <> nr or n <> nr then raise exception 'prodotti_non_validi'; end if;
  exception when invalid_text_representation or invalid_parameter_value or datatype_mismatch or numeric_value_out_of_range then
    raise exception 'prodotti_non_validi';
  end;
  insert into public.richieste_ritiro (bottega_id, cliente_id, ritiro_at, nota_cliente, scade_at)
  values (p_bottega, uid, p_ritiro, nullif(left(trim(coalesce(p_nota, '')), 300), ''), least(now() + make_interval(mins => private.richiesta_config('scadenza_min')), p_ritiro))
  returning id into rid;
  insert into public.richiesta_righe (richiesta_id, prodotto_id, nome, unita, prezzo_cent, quantita)
  select rid, p.id, p.nome, p.unita, p.prezzo_cent, x.quantita
    from jsonb_to_recordset(p_righe) as x(prodotto_id bigint, quantita numeric) join public.prodotti p on p.id = x.prodotto_id;
  perform private.richiesta_notifica(b.owner_id, uid, 'richiesta_nuova', rid);
  return rid;
end $$;

create or replace function public.richiesta_vista(p_id uuid) returns void
language sql security definer set search_path = '' as $$
  update public.richieste_ritiro r set stato = 'vista', visto_at = now(), updated_at = now()
  from public.botteghe b where r.id = p_id and b.id = r.bottega_id and b.owner_id = auth.uid() and r.stato = 'inviata'
$$;

create or replace function public.richiesta_rispondi(p_id uuid, p_azione text, p_motivo text default null, p_nuovo_ritiro timestamptz default null) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); q record; err text; sc int := private.richiesta_config('scadenza_min');
begin
  select r.id, r.bottega_id, r.cliente_id, r.stato, r.ritiro_at, r.scade_at, b.owner_id into q
    from public.richieste_ritiro r join public.botteghe b on b.id = r.bottega_id where r.id = p_id for update of r;
  if not found or uid is null or q.owner_id <> uid then raise exception 'non_autorizzato'; end if;
  if q.stato not in ('inviata','vista') then raise exception 'stato_non_valido'; end if;
  if q.scade_at is not null and q.scade_at <= now() then raise exception 'richiesta_scaduta'; end if;
  if p_azione = 'conferma' then
    update public.richieste_ritiro set stato = 'confermata', scade_at = null, risposto_at = now(), updated_at = now() where id = p_id;
    perform private.richiesta_notifica(q.cliente_id, uid, 'richiesta_confermata', p_id);
  elsif p_azione = 'rifiuta' then
    update public.richieste_ritiro set stato = 'rifiutata', scade_at = null, motivo_rifiuto = nullif(left(trim(coalesce(p_motivo, '')), 200), ''), risposto_at = now(), updated_at = now() where id = p_id;
    perform private.richiesta_notifica(q.cliente_id, uid, 'richiesta_rifiutata', p_id);
  elsif p_azione = 'proponi' then
    err := private.ritiro_errore(q.bottega_id, p_nuovo_ritiro);
    if err is not null then raise exception '%', err; end if;
    if p_nuovo_ritiro = q.ritiro_at then raise exception 'ritiro_non_valido'; end if;
    update public.richieste_ritiro set stato = 'proposta', ritiro_proposto_at = p_nuovo_ritiro, scade_at = least(now() + make_interval(mins => sc), p_nuovo_ritiro), risposto_at = now(), updated_at = now() where id = p_id;
    perform private.richiesta_notifica(q.cliente_id, uid, 'richiesta_proposta', p_id);
  else
    raise exception 'stato_non_valido';
  end if;
end $$;

create or replace function public.richiesta_risposta_cliente(p_id uuid, p_accetta boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); q record;
begin
  select r.id, r.cliente_id, r.stato, r.ritiro_proposto_at, r.scade_at, b.owner_id into q
    from public.richieste_ritiro r join public.botteghe b on b.id = r.bottega_id where r.id = p_id for update of r;
  if not found or uid is null or q.cliente_id <> uid then raise exception 'non_autorizzato'; end if;
  if q.stato <> 'proposta' then raise exception 'stato_non_valido'; end if;
  if q.scade_at is not null and q.scade_at <= now() then raise exception 'richiesta_scaduta'; end if;
  if p_accetta then
    update public.richieste_ritiro set stato = 'confermata', ritiro_at = q.ritiro_proposto_at, ritiro_proposto_at = null, scade_at = null, updated_at = now() where id = p_id;
    perform private.richiesta_notifica(q.owner_id, uid, 'richiesta_accettata', p_id);
  else
    update public.richieste_ritiro set stato = 'annullata', scade_at = null, updated_at = now() where id = p_id;
    perform private.richiesta_notifica(q.owner_id, uid, 'richiesta_annullata', p_id);
  end if;
end $$;

create or replace function public.richiesta_annulla(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); q record;
begin
  select r.id, r.cliente_id, r.stato, r.ritiro_at, b.owner_id into q
    from public.richieste_ritiro r join public.botteghe b on b.id = r.bottega_id where r.id = p_id for update of r;
  if not found or uid is null or q.cliente_id <> uid then raise exception 'non_autorizzato'; end if;
  if not (q.stato in ('inviata','vista','proposta') or (q.stato = 'confermata' and q.ritiro_at > now())) then raise exception 'stato_non_valido'; end if;
  update public.richieste_ritiro set stato = 'annullata', scade_at = null, updated_at = now() where id = p_id;
  perform private.richiesta_notifica(q.owner_id, uid, 'richiesta_annullata', p_id);
end $$;

create or replace function public.richiesta_esito(p_id uuid, p_esito text) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); q record;
begin
  select r.id, r.stato, r.ritiro_at, b.owner_id into q
    from public.richieste_ritiro r join public.botteghe b on b.id = r.bottega_id where r.id = p_id for update of r;
  if not found or uid is null or q.owner_id <> uid then raise exception 'non_autorizzato'; end if;
  if q.stato <> 'confermata' or q.ritiro_at > now() or p_esito not in ('ritirata','non_presentato') then raise exception 'stato_non_valido'; end if;
  update public.richieste_ritiro set stato = p_esito, updated_at = now() where id = p_id;
end $$;

revoke all on function public.richiesta_invia(bigint, timestamptz, jsonb, text), public.richiesta_vista(uuid), public.richiesta_rispondi(uuid, text, text, timestamptz),
  public.richiesta_risposta_cliente(uuid, boolean), public.richiesta_annulla(uuid), public.richiesta_esito(uuid, text) from public, anon;
grant execute on function public.richiesta_invia(bigint, timestamptz, jsonb, text), public.richiesta_vista(uuid), public.richiesta_rispondi(uuid, text, text, timestamptz),
  public.richiesta_risposta_cliente(uuid, boolean), public.richiesta_annulla(uuid), public.richiesta_esito(uuid, text) to authenticated;
