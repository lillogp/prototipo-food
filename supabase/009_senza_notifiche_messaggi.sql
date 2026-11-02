-- I messaggi non generano piu' notifiche (c'e' gia' la chat).
drop trigger if exists trg_notify_message on public.messages;
drop trigger if exists trg_notify_dm on public.dm_messages;
delete from public.notifications where type in ('message','dm','dm_request');
