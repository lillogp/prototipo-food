-- 039 · Botteghe: più categorie e coordinate per il navigatore (già applicato al database "Gusto").
-- `categorie` è l'elenco scelto; `categoria` resta come categoria principale (la prima) e un trigger le tiene allineate.
alter table public.botteghe
  add column if not exists categorie text[] not null default '{}'::text[],
  add column if not exists lat double precision,
  add column if not exists lon double precision;
update public.botteghe set categorie = array[categoria] where cardinality(categorie) = 0 and categoria is not null;
alter table public.botteghe
  add constraint botteghe_categorie_valide check (categorie <@ array['formaggi','macelleria','pescheria','ortofrutta','forno','uova','vino','dispensa']::text[] and cardinality(categorie) <= 8),
  add constraint botteghe_coordinate_valide check ((lat is null and lon is null) or (lat between -90 and 90 and lon between -180 and 180));
create or replace function public.botteghe_sync_categoria() returns trigger language plpgsql set search_path = public as $$
begin
  if cardinality(new.categorie) > 0 then new.categoria := new.categorie[1];
  elsif new.categoria is not null then new.categorie := array[new.categoria]; end if;
  return new;
end $$;
drop trigger if exists botteghe_sync_categoria on public.botteghe;
create trigger botteghe_sync_categoria before insert or update on public.botteghe for each row execute function public.botteghe_sync_categoria();
grant update (categorie, lat, lon) on public.botteghe to authenticated;
