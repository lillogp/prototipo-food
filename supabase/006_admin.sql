-- Pannello admin: verifica dei nutrizionisti, segnalazioni, sospensione degli account.
alter table public.profiles add column is_admin boolean not null default false;
alter table public.profiles add column suspended boolean not null default false;
-- Nessun utente puo' modificare queste due colonne: i permessi di UPDATE sono solo su nome, handle, titolo e privacy.

create function private.is_admin() returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select p.is_admin from public.profiles p where p.id = (select auth.uid())), false);
$$;
revoke execute on function private.is_admin() from public, anon;
grant execute on function private.is_admin() to authenticated;

-- Un account sospeso non e' piu' visibile agli altri (l'admin vede tutti).
drop policy "profili visibili" on public.profiles;
create policy "profili visibili" on public.profiles for select to authenticated using (
  private.is_admin()
  or (not private.blocked_pair(id) and (not suspended or id = (select auth.uid()))));

create function public.admin_stats() returns table (users bigint, pros bigint, pros_verified bigint, open_reports bigint)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  return query select
    (select count(*) from public.profiles),
    (select count(*) from public.profiles where account_type = 'pro'),
    (select count(*) from public.profiles where account_type = 'pro' and pro_verified),
    (select count(*) from public.reports where status = 'open');
end $$;

create function public.admin_pros() returns table (user_id uuid, name text, email text, pro_title text, pro_verified boolean, suspended boolean, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  return query select p.id, p.display_name, u.email::text, p.pro_title, p.pro_verified, p.suspended, p.created_at
    from public.profiles p join auth.users u on u.id = p.id
    where p.account_type = 'pro' order by p.pro_verified, p.created_at desc;
end $$;

create function public.admin_set_pro_verified(target uuid, ok boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  update public.profiles set pro_verified = ok where id = target and account_type = 'pro';
  if not found then raise exception 'nutrizionista non trovato'; end if;
end $$;

create function public.admin_reports(st text) returns table (report_id bigint, reporter_id uuid, reporter_name text, reported_id uuid, reported_name text,
  reported_email text, reported_suspended boolean, reason text, details text, conv_id bigint, status text, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  return query select r.id, r.reporter_id, rp.display_name, r.reported_id, rd.display_name, u.email::text, rd.suspended,
      r.reason, r.details, r.conv_id, r.status, r.created_at
    from public.reports r
    join public.profiles rp on rp.id = r.reporter_id
    join public.profiles rd on rd.id = r.reported_id
    join auth.users u on u.id = r.reported_id
    where (st = 'open' and r.status = 'open') or (st <> 'open' and r.status <> 'open')
    order by r.created_at desc limit 100;
end $$;

create function public.admin_report_set(rid bigint, new_status text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  if new_status not in ('open', 'reviewed', 'closed') then raise exception 'stato non valido'; end if;
  update public.reports set status = new_status where id = rid;
end $$;

-- Solo la conversazione indicata da chi ha segnalato, e solo se coinvolge davvero le due persone.
create function public.admin_report_messages(rid bigint) returns table (sender_name text, body text, created_at timestamptz, from_reported boolean)
language plpgsql security definer set search_path = '' as $$
declare r public.reports;
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  select * into r from public.reports where id = rid;
  if not found or r.conv_id is null then return; end if;
  if not exists (select 1 from public.conversations c where c.id = r.conv_id and r.reporter_id in (c.user_a, c.user_b) and r.reported_id in (c.user_a, c.user_b)) then return; end if;
  return query select pr.display_name, m.body, m.created_at, (m.sender_id = r.reported_id)
    from public.dm_messages m join public.profiles pr on pr.id = m.sender_id
    where m.conv_id = r.conv_id order by m.created_at limit 200;
end $$;

create function public.admin_set_suspended(target uuid, flag boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  if target = (select auth.uid()) then raise exception 'non puoi sospendere te stesso'; end if;
  update public.profiles set suspended = flag where id = target;
  update auth.users set banned_until = case when flag then now() + interval '100 years' else null end where id = target;
end $$;

revoke execute on function public.admin_stats(), public.admin_pros(), public.admin_set_pro_verified(uuid, boolean), public.admin_reports(text),
  public.admin_report_set(bigint, text), public.admin_report_messages(bigint), public.admin_set_suspended(uuid, boolean) from public, anon;
grant execute on function public.admin_stats(), public.admin_pros(), public.admin_set_pro_verified(uuid, boolean), public.admin_reports(text),
  public.admin_report_set(bigint, text), public.admin_report_messages(bigint), public.admin_set_suspended(uuid, boolean) to authenticated;

-- Amministratore: l'account principale del proprietario del progetto.
update public.profiles set is_admin = true where id = (select id from auth.users where email = 'teo91bongi@gmail.com');
