-- Promemoria al commerciante dopo 10 minuti senza risposta (una volta per richiesta). Già applicata su Supabase.
alter table public.richieste_ritiro add column if not exists promemoria_at timestamptz;
-- tipo 'richiesta_promemoria' aggiunto a notifications_type_check; funzione private.richieste_promemoria() + cron 'richieste-promemoria' (ogni minuto).
-- Provata in transazione annullata: avvisa solo inviata/vista di almeno 10 minuti non ancora scadute, una sola volta.
