-- Rispondere a un messaggio specifico
alter table public.dm_messages add column reply_to bigint references public.dm_messages(id) on delete set null;
create function public.dm_check_reply() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.reply_to is not null and not exists (select 1 from public.dm_messages m where m.id = new.reply_to and m.conv_id = new.conv_id) then
    raise exception 'risposta non valida';
  end if;
  return new;
end $$;
create trigger trg_dm_check_reply before insert on public.dm_messages for each row execute function public.dm_check_reply();
revoke execute on function public.dm_check_reply() from public, anon, authenticated;

-- Conferme di lettura e preferenze delle notifiche push
alter table public.profiles add column read_receipts boolean not null default true, add column push_prefs jsonb not null default '{}';
grant update (read_receipts, push_prefs) on public.profiles to authenticated;

-- Notifiche push: iscrizioni dei dispositivi
create table public.push_subscriptions (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
create index on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
create policy "vedo le mie iscrizioni" on public.push_subscriptions for select to authenticated using ((select auth.uid()) = user_id);
create policy "tolgo le mie iscrizioni" on public.push_subscriptions for delete to authenticated using ((select auth.uid()) = user_id);
create function public.register_push(p_endpoint text, p_p256dh text, p_auth text) returns void language sql security definer set search_path = '' as $$
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth) values ((select auth.uid()), p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
$$;
revoke execute on function public.register_push(text, text, text) from public, anon;
grant execute on function public.register_push(text, text, text) to authenticated;

-- Configurazione interna (chiavi VAPID e segreto del collegamento): nessuna policy, la legge solo la Edge Function
create table public.push_config (key text primary key, value text not null);
alter table public.push_config enable row level security;
revoke all on public.push_config from anon, authenticated;
insert into public.push_config (key, value) values ('hook_secret', gen_random_uuid()::text);

-- Chiamata alla Edge Function a ogni nuovo messaggio o notifica
create extension if not exists pg_net with schema extensions;
create function public.push_hook() returns trigger language plpgsql security definer set search_path = '' as $$
declare s text;
begin
  select value into s from public.push_config where key = 'hook_secret';
  perform net.http_post(
    url := 'https://qukvhsbaubithfabcfms.supabase.co/functions/v1/send-push',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook-secret', s),
    body := jsonb_build_object('table', tg_table_name, 'record', to_jsonb(new)));
  return new;
exception when others then
  return new;
end $$;
revoke execute on function public.push_hook() from public, anon, authenticated;
create trigger trg_push_dm after insert on public.dm_messages for each row execute function public.push_hook();
create trigger trg_push_notif after insert on public.notifications for each row execute function public.push_hook();
