-- Il cliente puo' scegliere di condividere le proprie allergie e intolleranze con il nutrizionista collegato.
-- Condivisione volontaria e revocabile: il dato sta nel collegamento e sparisce quando lo si revoca o il collegamento si chiude.
alter table public.client_links add column shared_allergens text[];
alter table public.client_links add column shared_allergens_at timestamptz;

-- allergens = null: smette di condividere. Un elenco (anche vuoto): condivide quell'elenco.
create function public.set_allergen_sharing(link bigint, allergens text[]) returns void
language plpgsql security definer set search_path = '' as $$
declare a text[];
begin
  if not exists (select 1 from public.client_links where id = link and client_id = (select auth.uid()) and status = 'active') then
    raise exception 'collegamento non valido';
  end if;
  if allergens is null then
    update public.client_links set shared_allergens = null, shared_allergens_at = null where id = link;
  else
    select coalesce(array_agg(x), '{}') into a from (select distinct x from unnest(allergens) x where char_length(x) between 1 and 30 limit 20) t;
    update public.client_links set shared_allergens = a, shared_allergens_at = now() where id = link;
  end if;
end $$;
revoke execute on function public.set_allergen_sharing(bigint, text[]) from public, anon;
grant execute on function public.set_allergen_sharing(bigint, text[]) to authenticated;

-- Alla chiusura del collegamento (da una delle due parti) i dati condivisi vengono cancellati.
create function private.clear_shared_on_end() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.status = 'ended' then new.shared_allergens := null; new.shared_allergens_at := null; end if;
  return new;
end $$;
create trigger client_links_clear_shared before update on public.client_links
  for each row execute function private.clear_shared_on_end();
