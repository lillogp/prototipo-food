-- Verifica dei nutrizionisti: il documento d'iscrizione all'albo si carica nell'app, in un'area privata, e si cancella dopo l'esame.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('pro-docs', 'pro-docs', false, 5242880, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy "pro-docs carico il mio" on storage.objects for insert to authenticated
  with check (bucket_id = 'pro-docs' and (storage.foldername(name))[1] = (select auth.uid())::text
    and exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.account_type = 'pro'));
create policy "pro-docs vedo il mio o admin" on storage.objects for select to authenticated
  using (bucket_id = 'pro-docs' and ((storage.foldername(name))[1] = (select auth.uid())::text or private.is_admin()));
create policy "pro-docs elimino il mio o admin" on storage.objects for delete to authenticated
  using (bucket_id = 'pro-docs' and ((storage.foldername(name))[1] = (select auth.uid())::text or private.is_admin()));

create table public.pro_verifications (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  albo text not null check (char_length(albo) between 2 and 80),
  albo_number text not null check (char_length(albo_number) between 1 and 40),
  doc_path text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  reject_reason text check (reject_reason is null or char_length(reject_reason) <= 300),
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz
);
alter table public.pro_verifications enable row level security;
create policy "vedo la mia verifica" on public.pro_verifications for select to authenticated using ((select auth.uid()) = user_id);
revoke all on public.pro_verifications from anon, authenticated;
grant select on public.pro_verifications to authenticated;

create function public.pro_submit_verification(p_albo text, p_number text, p_path text) returns void
language plpgsql security definer set search_path = '' as $$
declare me uuid := (select auth.uid());
begin
  if me is null then raise exception 'non autenticato'; end if;
  if not exists (select 1 from public.profiles where id = me and account_type = 'pro') then raise exception 'non e'' un nutrizionista'; end if;
  if exists (select 1 from public.profiles where id = me and pro_verified) then raise exception 'gia verificato'; end if;
  if p_path is null or split_part(p_path, '/', 1) <> me::text then raise exception 'documento non valido'; end if;
  insert into public.pro_verifications (user_id, albo, albo_number, doc_path, status, submitted_at)
    values (me, left(trim(p_albo), 80), left(trim(p_number), 40), p_path, 'pending', now())
  on conflict (user_id) do update set albo = excluded.albo, albo_number = excluded.albo_number, doc_path = excluded.doc_path,
    status = 'pending', reject_reason = null, submitted_at = now(), reviewed_at = null;
end $$;

create function public.admin_pro_list() returns table (user_id uuid, name text, email text, pro_title text, pro_verified boolean, suspended boolean, created_at timestamptz,
  albo text, albo_number text, doc_path text, status text, reject_reason text, submitted_at timestamptz, reviewed_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  return query select p.id, p.display_name, u.email::text, p.pro_title, p.pro_verified, p.suspended, p.created_at,
      v.albo, v.albo_number, v.doc_path, v.status, v.reject_reason, v.submitted_at, v.reviewed_at
    from public.profiles p join auth.users u on u.id = p.id left join public.pro_verifications v on v.user_id = p.id
    where p.account_type = 'pro'
    order by (v.status = 'pending') desc nulls last, p.pro_verified, p.created_at desc;
end $$;

create function public.admin_review_pro(target uuid, approve boolean, reason text) returns text
language plpgsql security definer set search_path = '' as $$
declare old text;
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  if not exists (select 1 from public.profiles where id = target and account_type = 'pro') then raise exception 'nutrizionista non trovato'; end if;
  if not approve and not exists (select 1 from public.pro_verifications where user_id = target) then raise exception 'nessuna richiesta'; end if;
  update public.profiles set pro_verified = approve where id = target;
  select doc_path into old from public.pro_verifications where user_id = target;
  update public.pro_verifications set status = case when approve then 'approved' else 'rejected' end,
    reject_reason = case when approve then null else left(reason, 300) end, reviewed_at = now(), doc_path = null where user_id = target;
  return old;
end $$;

revoke execute on function public.pro_submit_verification(text, text, text), public.admin_pro_list(), public.admin_review_pro(uuid, boolean, text) from public, anon;
grant execute on function public.pro_submit_verification(text, text, text), public.admin_pro_list(), public.admin_review_pro(uuid, boolean, text) to authenticated;
