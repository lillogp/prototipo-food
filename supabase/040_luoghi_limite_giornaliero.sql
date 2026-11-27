-- Contatore globale giornaliero delle richieste di suggerimenti a Google (già applicato su Supabase).
create table if not exists private.luoghi_uso (giorno date primary key, n integer not null default 0);

create or replace function public.luoghi_conta(p_limite integer)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v integer;
begin
  insert into private.luoghi_uso (giorno, n)
  values ((now() at time zone 'Europe/Rome')::date, 1)
  on conflict (giorno) do update set n = private.luoghi_uso.n + 1
  where private.luoghi_uso.n < p_limite
  returning n into v;
  return v is not null;
end;
$$;

revoke all on function public.luoghi_conta(integer) from public, anon;
grant execute on function public.luoghi_conta(integer) to authenticated;
