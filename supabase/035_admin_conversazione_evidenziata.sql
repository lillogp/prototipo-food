-- Conversazione segnalata per l'admin, con il messaggio segnalato evidenziato.
-- content_type 'message' -> is_target vero solo per quel messaggio (finestra di contesto intorno).
-- content_type 'chat' (o vecchie segnalazioni con solo conv_id) -> tutta la chat (ultimi 200 messaggi).
create or replace function public.admin_report_messages2(rid bigint)
returns table (msg_id bigint, sender_name text, body text, created_at timestamptz, from_reported boolean, is_target boolean, scope text)
language plpgsql security definer set search_path = '' as $$
declare r public.reports; tid bigint; tat timestamptz; sc text;
begin
  if not private.is_admin() then raise exception 'non autorizzato'; end if;
  select * into r from public.reports where id = rid;
  if not found or r.conv_id is null then return; end if;
  if not exists (select 1 from public.conversations c where c.id = r.conv_id and r.reporter_id in (c.user_a, c.user_b) and r.reported_id in (c.user_a, c.user_b)) then return; end if;
  if r.content_type = 'message' and r.content_id ~ '^[0-9]+$' then
    select m.id, m.created_at into tid, tat from public.dm_messages m where m.id = r.content_id::bigint and m.conv_id = r.conv_id;
  end if;
  sc := case when tid is not null then 'message' else 'chat' end;
  return query
    select m.id, pr.display_name, m.body, m.created_at, (m.sender_id = r.reported_id), (tid is not null and m.id = tid), sc
    from (
      select * from (select x.* from public.dm_messages x where x.conv_id = r.conv_id and (tid is null or x.created_at <= tat) order by x.created_at desc, x.id desc limit 100) b
      union
      select * from (select x.* from public.dm_messages x where x.conv_id = r.conv_id and tid is not null and x.created_at > tat order by x.created_at, x.id limit 100) a
    ) m join public.profiles pr on pr.id = m.sender_id
    order by m.created_at, m.id;
end $$;
revoke execute on function public.admin_report_messages2(bigint) from public, anon;
grant execute on function public.admin_report_messages2(bigint) to authenticated;
