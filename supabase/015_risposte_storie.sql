-- Una risposta in chat puo' riferirsi a una storia (per mostrarne la miniatura).
alter table public.dm_messages add column story_id uuid;
