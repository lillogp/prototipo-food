-- Messaggi diretti tra utenti, con richieste di messaggio (come Instagram).
create table public.conversations (
  id bigint generated always as identity primary key,
  user_a uuid not null references public.profiles(id) on delete cascade,
  user_b uuid not null references public.profiles(id) on delete cascade,
  initiator uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','active','declined')),
  created_at timestamptz not null default now(),
  check (user_a < user_b),
  unique (user_a, user_b)
);
create index on public.conversations (user_b);
alter table public.conversations enable row level security;
create policy "vedo le mie conversazioni" on public.conversations for select to authenticated
  using ((select auth.uid()) in (user_a, user_b));
create policy "avvio una conversazione" on public.conversations for insert to authenticated
  with check ((select auth.uid()) in (user_a, user_b));
create policy "rispondo a una richiesta" on public.conversations for update to authenticated
  using ((select auth.uid()) in (user_a, user_b) and (select auth.uid()) <> initiator and status = 'pending')
  with check ((select auth.uid()) <> initiator and status in ('active', 'declined'));
revoke update on public.conversations from authenticated;
grant update (status) on public.conversations to authenticated;

-- Iniziatore e stato li decide il database: e' attiva solo se il destinatario segue gia chi scrive.
create function public.conv_before_insert() returns trigger language plpgsql security definer set search_path = '' as $$
declare other uuid;
begin
  new.initiator := (select auth.uid());
  other := case when new.initiator = new.user_a then new.user_b else new.user_a end;
  new.status := case when exists (
    select 1 from public.follows f where f.follower_id = other and f.followed_id = new.initiator and f.status = 'accepted'
  ) then 'active' else 'pending' end;
  return new;
end $$;
create trigger trg_conv_before_insert before insert on public.conversations for each row execute function public.conv_before_insert();
revoke execute on function public.conv_before_insert() from public, anon, authenticated;

create table public.dm_messages (
  id bigint generated always as identity primary key,
  conv_id bigint not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 300),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index on public.dm_messages (conv_id, created_at);
alter table public.dm_messages enable row level security;
create policy "leggo i messaggi delle mie conversazioni" on public.dm_messages for select to authenticated
  using (exists (select 1 from public.conversations c where c.id = conv_id
    and (select auth.uid()) in (c.user_a, c.user_b) and not (c.status = 'declined' and (select auth.uid()) <> c.initiator)));
create policy "scrivo nelle mie conversazioni" on public.dm_messages for insert to authenticated
  with check ((select auth.uid()) = sender_id and exists (select 1 from public.conversations c where c.id = conv_id
    and (select auth.uid()) in (c.user_a, c.user_b)
    and (c.status = 'active' or (c.status = 'pending' and c.initiator = (select auth.uid())))));
-- In una richiesta pendente chi scrive puo mandare un solo messaggio (controllo nel trigger: una policy non puo rileggere la stessa tabella).
create function public.dm_before_insert() returns trigger language plpgsql security definer set search_path = '' as $$
declare c public.conversations;
begin
  select * into c from public.conversations where id = new.conv_id;
  if c.status = 'pending' and exists (select 1 from public.dm_messages m where m.conv_id = new.conv_id and m.sender_id = new.sender_id) then
    raise exception 'richiesta gia inviata: attendi che venga accettata';
  end if;
  return new;
end $$;
create trigger trg_dm_before_insert before insert on public.dm_messages for each row execute function public.dm_before_insert();
revoke execute on function public.dm_before_insert() from public, anon, authenticated;
create policy "segno come letti" on public.dm_messages for update to authenticated
  using (sender_id <> (select auth.uid()) and exists (select 1 from public.conversations c where c.id = conv_id and (select auth.uid()) in (c.user_a, c.user_b)))
  with check (sender_id <> (select auth.uid()));
revoke update on public.dm_messages from authenticated;
grant update (read_at) on public.dm_messages to authenticated;

-- Notifiche per i messaggi diretti
alter table public.notifications drop constraint notifications_type_check;
alter table public.notifications add constraint notifications_type_check
  check (type in ('follow','follow_request','follow_accepted','like','comment','client_joined','plan','message','dm','dm_request'));

create function public.notify_dm() returns trigger language plpgsql security definer set search_path = '' as $$
declare c public.conversations; r uuid;
begin
  select * into c from public.conversations where id = new.conv_id;
  r := case when new.sender_id = c.user_a then c.user_b else c.user_a end;
  if not exists (select 1 from public.notifications where user_id = r and type in ('dm', 'dm_request') and read_at is null and ref->>'conv_id' = new.conv_id::text) then
    insert into public.notifications (user_id, actor_id, type, ref)
    values (r, new.sender_id, case when c.status = 'pending' then 'dm_request' else 'dm' end, jsonb_build_object('conv_id', new.conv_id));
  end if;
  return new;
end $$;
create trigger trg_notify_dm after insert on public.dm_messages for each row execute function public.notify_dm();
revoke execute on function public.notify_dm() from public, anon, authenticated;
