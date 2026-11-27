-- Abuela, fase 3: valutazioni 1-10 tra cliente e bottega, segnalazioni e provvedimenti dell'admin.
-- Le tabelle non hanno policy: si legge e si scrive solo con le funzioni sotto (regole e privacy in un punto solo).

alter table public.profiles add column if not exists abuela_blocco_fino timestamptz;   -- cliente: store nascosti fino a...
alter table public.botteghe add column if not exists nascosta_fino timestamptz;        -- bottega: nascosta ai clienti fino a...

-- ===== Valutazioni ==========================================================
create table public.valutazioni (
  id bigint generated always as identity primary key,
  richiesta_id uuid not null references public.richieste_ritiro(id) on delete cascade,
  bottega_id bigint not null references public.botteghe(id) on delete cascade,
  autore_id uuid not null references public.profiles(id) on delete cascade,
  destinatario_id uuid not null references public.profiles(id) on delete cascade,
  verso text not null check (verso in ('bottega', 'cliente')),     -- chi viene valutato
  voto smallint not null check (voto between 1 and 10),
  commento text check (char_length(commento) <= 300),
  motivi text[] not null default '{}',
  nascosta boolean not null default false,                         -- rimossa da un admin
  created_at timestamptz not null default now(),
  unique (richiesta_id, verso)
);
create index valutazioni_bottega_idx on public.valutazioni (bottega_id, verso);
create index valutazioni_dest_idx on public.valutazioni (destinatario_id, verso);
alter table public.valutazioni enable row level security;
revoke all on public.valutazioni from anon, authenticated;

-- Un voto si vede quando l'altra parte ha votato, oppure dopo 7 giorni, oppure se il cliente non si è presentato (l'altra parte non può votare).
create or replace function private.val_visibile(p_richiesta uuid, p_verso text, p_creata timestamptz) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_creata + interval '7 days' <= now()
    or exists (select 1 from public.valutazioni o where o.richiesta_id = p_richiesta and o.verso <> p_verso)
    or exists (select 1 from public.richieste_ritiro r where r.id = p_richiesta and r.stato = 'non_presentato')
$$;

create or replace function private.abuela_bloccato() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select abuela_blocco_fino > now() from public.profiles where id = (select auth.uid())), false)
$$;

create or replace function private.val_riassunto(p_verso text, p_bottega bigint, p_cliente uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with v as (
    select x.*, case when x.verso = 'bottega' then split_part(coalesce(pa.display_name, ''), ' ', 1) else b.nome end as da
    from public.valutazioni x
    join public.profiles pa on pa.id = x.autore_id
    join public.botteghe b on b.id = x.bottega_id
    where not x.nascosta and x.verso = p_verso
      and ((p_verso = 'bottega' and x.bottega_id = p_bottega) or (p_verso = 'cliente' and x.destinatario_id = p_cliente))
      and private.val_visibile(x.richiesta_id, x.verso, x.created_at)
  )
  select jsonb_build_object(
    'n', (select count(*) from v),
    'media', (select case when count(*) >= 3 then round(avg(voto)::numeric, 1) end from v),
    'elenco', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (select id, voto, commento, motivi, created_at, da from v order by created_at desc limit 30) t)
  )
$$;

create or replace function public.valutazione_invia(p_richiesta uuid, p_voto int, p_commento text default null, p_motivi text[] default '{}') returns bigint
language plpgsql security definer set search_path = '' as $$
declare r public.richieste_ritiro%rowtype; me uuid := (select auth.uid()); b public.botteghe%rowtype; v_verso text; v_dest uuid; vid bigint;
  ok_bottega text[] := array['qualita','puntualita','correttezza','prodotto_scadente','attesa_lunga','gentilezza'];
  ok_cliente text[] := array['puntuale','in_ritardo','non_presentato','gentile','scortese'];
  c text := nullif(left(btrim(coalesce(p_commento, '')), 300), '');
begin
  select * into r from public.richieste_ritiro where id = p_richiesta;
  if not found then raise exception 'non_autorizzato'; end if;
  select * into b from public.botteghe where id = r.bottega_id;
  if p_voto is null or p_voto < 1 or p_voto > 10 then raise exception 'voto_non_valido'; end if;
  if me = r.cliente_id then
    if r.stato <> 'ritirata' then raise exception 'stato_non_valido'; end if;
    v_verso := 'bottega'; v_dest := b.owner_id;
    if not (coalesce(p_motivi, '{}') <@ ok_bottega) then raise exception 'motivi_non_validi'; end if;
  elsif me = b.owner_id then
    if r.stato not in ('ritirata', 'non_presentato') then raise exception 'stato_non_valido'; end if;
    v_verso := 'cliente'; v_dest := r.cliente_id;
    if not (coalesce(p_motivi, '{}') <@ ok_cliente) then raise exception 'motivi_non_validi'; end if;
  else
    raise exception 'non_autorizzato';
  end if;
  if r.ritiro_at < now() - interval '30 days' then raise exception 'finestra_chiusa'; end if;
  begin
    insert into public.valutazioni (richiesta_id, bottega_id, autore_id, destinatario_id, verso, voto, commento, motivi)
    values (r.id, r.bottega_id, me, v_dest, v_verso, p_voto, c, coalesce(p_motivi, '{}')) returning id into vid;
  exception when unique_violation then raise exception 'gia_valutata';
  end;
  return vid;
end $$;

-- Valutazioni pubbliche di una bottega (chi può vedere la bottega).
create or replace function public.valutazioni_bottega(p_bottega bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (private.is_admin()
       or exists (select 1 from public.botteghe b where b.id = p_bottega and b.owner_id = (select auth.uid()))
       or (private.can_abuela() and not private.abuela_bloccato()
           and exists (select 1 from public.botteghe b where b.id = p_bottega and (b.nascosta_fino is null or b.nascosta_fino < now())))) then
    raise exception 'non_autorizzato';
  end if;
  return private.val_riassunto('bottega', p_bottega, null);
end $$;

-- Valutazioni di un cliente: solo per il commerciante che ha ricevuto una sua richiesta (e per gli admin).
create or replace function public.valutazioni_cliente(p_cliente uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (private.is_admin() or exists (
      select 1 from public.richieste_ritiro r join public.botteghe b on b.id = r.bottega_id
      where r.cliente_id = p_cliente and b.owner_id = (select auth.uid()))) then
    raise exception 'non_autorizzato';
  end if;
  return private.val_riassunto('cliente', null, p_cliente);
end $$;

-- Per le liste di richieste: per ciascuna, se ho già votato e il voto ricevuto (se ormai visibile).
create or replace function public.valutazioni_stato(p_ids uuid[]) returns table (richiesta_id uuid, data boolean, ricevuto_voto smallint, ricevuto_commento text)
language sql stable security definer set search_path = '' as $$
  select r.id,
    exists (select 1 from public.valutazioni v where v.richiesta_id = r.id and v.autore_id = (select auth.uid())),
    (select v.voto from public.valutazioni v where v.richiesta_id = r.id and v.destinatario_id = (select auth.uid()) and not v.nascosta and private.val_visibile(v.richiesta_id, v.verso, v.created_at)),
    (select v.commento from public.valutazioni v where v.richiesta_id = r.id and v.destinatario_id = (select auth.uid()) and not v.nascosta and private.val_visibile(v.richiesta_id, v.verso, v.created_at))
  from public.richieste_ritiro r
  where r.id = any (p_ids)
    and (r.cliente_id = (select auth.uid()) or exists (select 1 from public.botteghe b where b.id = r.bottega_id and b.owner_id = (select auth.uid())))
$$;

-- ===== Segnalazioni =========================================================
create table public.abuela_segnalazioni (
  id bigint generated always as identity primary key,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  tipo text not null check (tipo in ('utente', 'bottega', 'valutazione')),
  target_user uuid not null references public.profiles(id) on delete cascade,
  bottega_id bigint references public.botteghe(id) on delete set null,
  valutazione_id bigint references public.valutazioni(id) on delete set null,
  richiesta_id uuid references public.richieste_ritiro(id) on delete set null,
  motivo text not null check (motivo in ('non_presentato', 'ritardo', 'prodotto_scadente', 'comportamento', 'falso', 'altro')),
  testo text check (char_length(testo) <= 500),
  stato text not null default 'aperta' check (stato in ('aperta', 'chiusa')),
  esito text,
  created_at timestamptz not null default now(),
  check (reporter_id <> target_user)
);
create unique index abuela_segn_unica on public.abuela_segnalazioni (reporter_id, target_user, tipo) where stato = 'aperta';
create index abuela_segn_stato on public.abuela_segnalazioni (stato, created_at desc);
alter table public.abuela_segnalazioni enable row level security;
revoke all on public.abuela_segnalazioni from anon, authenticated;

create table public.abuela_provvedimenti (
  id bigint generated always as identity primary key,
  admin_id uuid references public.profiles(id) on delete set null,
  user_id uuid references public.profiles(id) on delete set null,
  bottega_id bigint,
  valutazione_id bigint,
  segnalazione_id bigint,
  tipo text not null check (tipo in ('avvertimento', 'blocco_store', 'bottega_nascosta', 'bottega_eliminata', 'valutazione_rimossa', 'revoca')),
  fino timestamptz,
  motivo text,
  created_at timestamptz not null default now()
);
alter table public.abuela_provvedimenti enable row level security;
revoke all on public.abuela_provvedimenti from anon, authenticated;

-- Segnala un utente, una bottega o una valutazione. Serve una richiesta in comune per segnalare un utente o una valutazione.
create or replace function public.abuela_segnala(p_tipo text, p_richiesta uuid, p_valutazione bigint, p_motivo text, p_testo text default null) returns bigint
language plpgsql security definer set search_path = '' as $$
declare me uuid := (select auth.uid()); r public.richieste_ritiro%rowtype; b public.botteghe%rowtype; v public.valutazioni%rowtype;
  tgt uuid; sid bigint; t text := nullif(left(btrim(coalesce(p_testo, '')), 500), '');
begin
  if not (private.can_abuela() or private.is_admin()) then raise exception 'non_autorizzato'; end if;
  if p_tipo not in ('utente', 'bottega', 'valutazione') then raise exception 'tipo_non_valido'; end if;
  if p_tipo = 'valutazione' then
    select * into v from public.valutazioni where id = p_valutazione and not nascosta;
    if not found or v.destinatario_id <> me then raise exception 'non_autorizzato'; end if;   -- si segnala una valutazione ricevuta
    tgt := v.autore_id; select * into b from public.botteghe where id = v.bottega_id; r.id := v.richiesta_id;
  else
    select * into r from public.richieste_ritiro where id = p_richiesta;
    if not found then raise exception 'non_autorizzato'; end if;
    select * into b from public.botteghe where id = r.bottega_id;
    if me = r.cliente_id then tgt := b.owner_id;
    elsif me = b.owner_id then tgt := r.cliente_id;
    else raise exception 'non_autorizzato'; end if;
    if p_tipo = 'bottega' and me <> r.cliente_id then raise exception 'non_autorizzato'; end if;
    if p_tipo = 'utente' and me <> b.owner_id then raise exception 'non_autorizzato'; end if;
  end if;
  begin
    insert into public.abuela_segnalazioni (reporter_id, tipo, target_user, bottega_id, valutazione_id, richiesta_id, motivo, testo)
    values (me, p_tipo, tgt, b.id, case when p_tipo = 'valutazione' then v.id end, r.id, p_motivo, t) returning id into sid;
  exception when unique_violation then raise exception 'gia_segnalata';
           when check_violation then raise exception 'dati_non_validi';
  end;
  return sid;
end $$;

-- ===== Admin ================================================================
create or replace function public.admin_abuela_segnalazioni(p_stato text default 'aperta') returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non_autorizzato'; end if;
  return (select coalesce(jsonb_agg(t order by t.created_at desc), '[]'::jsonb) from (
    select s.id, s.tipo, s.motivo, s.testo, s.stato, s.esito, s.created_at, s.target_user, s.bottega_id, s.valutazione_id,
      coalesce(pt.display_name, pt.handle, 'Senza nome') as target_nome, pt.abuela_blocco_fino as target_blocco,
      coalesce(pr.display_name, pr.handle, 'Senza nome') as reporter_nome, b.nome as bottega_nome, b.nascosta_fino as bottega_nascosta_fino,
      v.voto as val_voto, v.commento as val_commento,
      (select count(*) from public.abuela_segnalazioni x where x.target_user = s.target_user and x.id <> s.id) as altre_segnalazioni
    from public.abuela_segnalazioni s
    join public.profiles pt on pt.id = s.target_user join public.profiles pr on pr.id = s.reporter_id
    left join public.botteghe b on b.id = s.bottega_id left join public.valutazioni v on v.id = s.valutazione_id
    where s.stato = p_stato order by s.created_at desc limit 100) t);
end $$;

-- Provvedimenti. Ogni azione è registrata e l'interessato riceve un avviso con il motivo.
--   avvertimento | blocco_store (cliente, p_giorni) | bottega_nascosta (p_giorni) | bottega_eliminata | valutazione_rimossa | revoca (toglie blocchi)
create or replace function public.admin_abuela_provvedimento(p_tipo text, p_user uuid, p_bottega bigint, p_valutazione bigint, p_giorni int, p_motivo text, p_segnalazione bigint default null) returns void
language plpgsql security definer set search_path = '' as $$
declare m text := btrim(coalesce(p_motivo, '')); fino timestamptz; testo text; uid uuid := p_user; wid bigint;
begin
  if not private.is_admin() then raise exception 'non_autorizzato'; end if;
  if char_length(m) < 3 or char_length(m) > 250 then raise exception 'motivo_non_valido'; end if;
  if p_tipo in ('blocco_store', 'bottega_nascosta') and (p_giorni is null or p_giorni < 1 or p_giorni > 365) then raise exception 'durata_non_valida'; end if;
  if p_tipo in ('bottega_nascosta', 'bottega_eliminata') then
    select owner_id into uid from public.botteghe where id = p_bottega;
    if uid is null then raise exception 'bottega_non_trovata'; end if;
  end if;
  if p_tipo = 'valutazione_rimossa' then
    select autore_id into uid from public.valutazioni where id = p_valutazione;
    if uid is null then raise exception 'valutazione_non_trovata'; end if;
  end if;
  if uid is null or not exists (select 1 from public.profiles where id = uid) then raise exception 'utente_non_trovato'; end if;
  if exists (select 1 from public.profiles where id = uid and (is_admin or is_owner)) and p_tipo <> 'avvertimento' then raise exception 'non_autorizzato'; end if;

  if p_tipo = 'avvertimento' then
    testo := 'Avvertimento da Abuela Frog: ' || m;
  elsif p_tipo = 'blocco_store' then
    fino := now() + make_interval(days => p_giorni);
    update public.profiles set abuela_blocco_fino = fino where id = uid;
    testo := 'Non puoi vedere le botteghe di Abuela Frog fino al ' || to_char(fino at time zone 'Europe/Rome', 'DD/MM/YYYY') || '. Motivo: ' || m;
  elsif p_tipo = 'bottega_nascosta' then
    fino := now() + make_interval(days => p_giorni);
    update public.botteghe set nascosta_fino = fino where id = p_bottega;
    testo := 'La tua bottega è nascosta ai clienti fino al ' || to_char(fino at time zone 'Europe/Rome', 'DD/MM/YYYY') || '. Motivo: ' || m;
  elsif p_tipo = 'bottega_eliminata' then
    testo := 'La tua bottega è stata rimossa da Abuela Frog. Motivo: ' || m;
    delete from public.botteghe where id = p_bottega;
  elsif p_tipo = 'valutazione_rimossa' then
    update public.valutazioni set nascosta = true where id = p_valutazione;
    testo := 'Una tua valutazione è stata rimossa. Motivo: ' || m;
  elsif p_tipo = 'revoca' then
    update public.profiles set abuela_blocco_fino = null where id = uid;
    if p_bottega is not null then update public.botteghe set nascosta_fino = null where id = p_bottega; end if;
    testo := 'Le restrizioni su Abuela Frog sono state tolte.';
  else
    raise exception 'tipo_non_valido';
  end if;

  insert into public.abuela_provvedimenti (admin_id, user_id, bottega_id, valutazione_id, segnalazione_id, tipo, fino, motivo)
  values ((select auth.uid()), uid, p_bottega, p_valutazione, p_segnalazione, p_tipo, fino, m);
  insert into public.admin_warnings (user_id, admin_id, reason, body) values (uid, (select auth.uid()), left('Abuela Frog', 60), left(testo, 300)) returning id into wid;
  insert into public.notifications (user_id, actor_id, type, ref) values (uid, null, 'admin_warning', jsonb_build_object('reason', 'Abuela Frog', 'body', left(testo, 300), 'wid', wid));
  if p_segnalazione is not null then
    update public.abuela_segnalazioni set stato = 'chiusa', esito = p_tipo where id = p_segnalazione;
  end if;
end $$;

create or replace function public.admin_abuela_chiudi_segnalazione(p_id bigint, p_esito text default 'nessun_provvedimento') returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non_autorizzato'; end if;
  update public.abuela_segnalazioni set stato = 'chiusa', esito = left(coalesce(p_esito, 'nessun_provvedimento'), 60) where id = p_id;
end $$;

-- ===== Applicazione dei blocchi ============================================
-- Un cliente bloccato non vede le botteghe; una bottega nascosta non si vede (resta visibile al titolare e agli admin).
drop policy if exists "botteghe visibili in anteprima" on public.botteghe;
create policy "botteghe visibili in anteprima" on public.botteghe for select to authenticated
  using (owner_id = (select auth.uid()) or private.is_admin()
    or (private.can_abuela() and not private.abuela_bloccato() and (nascosta_fino is null or nascosta_fino < now())));
drop policy if exists "prodotti visibili in anteprima" on public.prodotti;
create policy "prodotti visibili in anteprima" on public.prodotti for select to authenticated
  using (exists (select 1 from public.botteghe b where b.id = bottega_id
    and (b.owner_id = (select auth.uid()) or private.is_admin()
      or (private.can_abuela() and not private.abuela_bloccato() and (b.nascosta_fino is null or b.nascosta_fino < now())))));

-- Le richieste a una bottega nascosta o da un cliente bloccato non partono (le funzioni di richiesta girano senza RLS).
create or replace function private.richiesta_blocchi() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.profiles where id = new.cliente_id and abuela_blocco_fino > now()) then raise exception 'bloccato'; end if;
  if exists (select 1 from public.botteghe where id = new.bottega_id and nascosta_fino > now()) then raise exception 'bottega_non_prenotabile'; end if;
  return new;
end $$;
drop trigger if exists richiesta_blocchi on public.richieste_ritiro;
create trigger richiesta_blocchi before insert on public.richieste_ritiro for each row execute function private.richiesta_blocchi();

-- ===== Permessi =============================================================
revoke execute on function public.valutazione_invia(uuid, int, text, text[]), public.valutazioni_bottega(bigint), public.valutazioni_cliente(uuid), public.valutazioni_stato(uuid[]),
  public.abuela_segnala(text, uuid, bigint, text, text), public.admin_abuela_segnalazioni(text),
  public.admin_abuela_provvedimento(text, uuid, bigint, bigint, int, text, bigint), public.admin_abuela_chiudi_segnalazione(bigint, text) from public, anon;
grant execute on function public.valutazione_invia(uuid, int, text, text[]), public.valutazioni_bottega(bigint), public.valutazioni_cliente(uuid), public.valutazioni_stato(uuid[]),
  public.abuela_segnala(text, uuid, bigint, text, text), public.admin_abuela_segnalazioni(text),
  public.admin_abuela_provvedimento(text, uuid, bigint, bigint, int, text, bigint), public.admin_abuela_chiudi_segnalazione(bigint, text) to authenticated;
