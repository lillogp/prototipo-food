-- Ricette online: media, archivio file, mi piace e commenti visibili solo se la ricetta e' visibile.
alter table public.recipes add column media_type text not null default 'image' check (media_type in ('image','video'));
alter table public.recipes add column from_info jsonb;
alter table public.recipes add constraint recipes_size check (jsonb_array_length(ingredients) <= 60 and jsonb_array_length(steps) <= 40);

-- Archivio dei file: foto e brevi video, massimo 20 MB a file. Ognuno scrive solo nella propria cartella.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', true, 20971520, array['image/jpeg','image/png','image/webp','video/mp4','video/webm','video/quicktime'])
on conflict (id) do nothing;
create policy "carico nella mia cartella" on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "elimino i miei file" on storage.objects for delete to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- Mi piace, commenti e salvati: solo su ricette che l'utente puo' vedere.
drop policy "mi piace visibili" on public.likes;
create policy "mi piace visibili" on public.likes for select to authenticated using (exists (select 1 from public.recipes r where r.id = recipe_id));
drop policy "metto mi piace" on public.likes;
create policy "metto mi piace" on public.likes for insert to authenticated
  with check ((select auth.uid()) = user_id and exists (select 1 from public.recipes r where r.id = recipe_id));

drop policy "commenti visibili" on public.comments;
create policy "commenti visibili" on public.comments for select to authenticated using (exists (select 1 from public.recipes r where r.id = recipe_id));
drop policy "commento" on public.comments;
create policy "commento" on public.comments for insert to authenticated
  with check ((select auth.uid()) = author_id and exists (select 1 from public.recipes r where r.id = recipe_id));

drop policy "salvo" on public.saves;
create policy "salvo" on public.saves for insert to authenticated
  with check ((select auth.uid()) = user_id and exists (select 1 from public.recipes r where r.id = recipe_id));
