-- Ricette importate da un link: restano solo nel ricettario personale di chi le importa.
-- source_url / source_site dicono da dove arrivano. Se source_url e' valorizzato la ricetta e' sempre privata:
-- non si puo' pubblicare, e la fonte non si puo' cancellare ne' cambiare.
alter table public.recipes
  add column source_url text check (source_url is null or char_length(source_url) <= 2000),
  add column source_site text check (source_site is null or char_length(source_site) <= 120);

create function public.blocca_pubblicazione_importate() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and old.source_url is not null then
    new.source_url := old.source_url;
    new.source_site := old.source_site;
  end if;
  if new.source_url is not null and not new.is_private then
    raise exception 'Le ricette importate restano nel tuo ricettario personale.' using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke execute on function public.blocca_pubblicazione_importate() from public, anon, authenticated;
create trigger trg_blocca_pubblicazione_importate before insert or update on public.recipes
  for each row execute function public.blocca_pubblicazione_importate();
