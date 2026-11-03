-- Menu: piu' piatti pubblicati insieme (carosello nel feed).
alter table public.recipes add column menu_id uuid, add column menu_name text, add column menu_pos int;
create index on public.recipes (menu_id);
