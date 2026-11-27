-- 038 · Orari di apertura per giorno delle botteghe (già applicato al database "Gusto").
-- Formato: {"lun":"7:30–13:00, 16:00–19:30","mar":"...", ...}; un giorno assente = chiuso. La colonna "orari" (testo libero) resta per le botteghe vecchie.
alter table public.botteghe
  add column if not exists orari_sett jsonb not null default '{}'::jsonb
  check (jsonb_typeof(orari_sett) = 'object' and pg_column_size(orari_sett) < 1000);
grant update (orari_sett) on public.botteghe to authenticated;
