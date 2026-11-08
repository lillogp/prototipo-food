-- Accesso con Google: il nome del profilo viene preso dall'account Google se non e' stato fornito.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, display_name, account_type)
  values (new.id, left(coalesce(nullif(new.raw_user_meta_data->>'display_name', ''), new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', ''), 40),
          case when new.raw_user_meta_data->>'account_type' = 'pro' then 'pro' else 'user' end);
  insert into public.user_data (user_id) values (new.id);
  return new;
end $$;
