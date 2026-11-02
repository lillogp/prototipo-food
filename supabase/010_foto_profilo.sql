-- Foto profilo: URL pubblico del file in storage (media/<uid>/avatar-...). Il file viene caricato dall'app con le policy storage esistenti.
alter table public.profiles add column avatar_url text;
grant update (avatar_url) on public.profiles to authenticated;
