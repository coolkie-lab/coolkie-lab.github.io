-- Coolkie : base de données (à coller une seule fois dans Supabase > SQL Editor > New query > Run)

create extension if not exists pgcrypto;

-- ---------- Tables ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  tel text default '',
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  nom text not null,
  description text default '',
  photo text default '',
  prix numeric(10,2) not null default 0,
  cout numeric(10,2) not null default 0,
  unite text default '',
  stock integer not null default 0,
  seuil integer not null default 5,
  actif boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.orders (
  id bigint generated always as identity primary key,
  user_id uuid references public.profiles(id) on delete set null,
  client_nom text not null default '',
  client_tel text default '',
  lignes jsonb not null default '[]',
  total numeric(10,2) not null default 0,
  point text not null default 'uccle' check (point in ('uccle','woluwe','livraison','autre')),
  date_retrait date not null default current_date,
  statut text not null default 'a_preparer' check (statut in ('a_preparer','prete','livree','annulee')),
  paye boolean not null default false,
  paiement text default 'cash',
  notes text default '',
  stock_deduit boolean not null default false,
  source text not null default 'en_ligne' check (source in ('en_ligne','manuel')),
  created_at timestamptz not null default now()
);

create table if not exists public.messages (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade, -- le client de la conversation
  from_admin boolean not null default false,
  body text not null check (length(body) between 1 and 2000),
  lu boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.production (
  id bigint generated always as identity primary key,
  product_id uuid references public.products(id) on delete set null,
  nom text not null,
  qte integer not null,
  date date not null default current_date,
  created_at timestamptz not null default now()
);

-- ---------- Helpers ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;

-- Profil créé automatiquement à l'inscription (pseudo passé dans les métadonnées)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username, tel)
  values (new.id, lower(new.raw_user_meta_data->>'username'), coalesce(new.raw_user_meta_data->>'tel',''));
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Sécurité (RLS) ----------
alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.messages enable row level security;
alter table public.production enable row level security;

drop policy if exists p_read on public.profiles;
create policy p_read on public.profiles for select using (id = auth.uid() or public.is_admin());
drop policy if exists p_update_own on public.profiles;
create policy p_update_own on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from authenticated, anon;
grant update (tel) on public.profiles to authenticated;

drop policy if exists pr_read on public.products;
create policy pr_read on public.products for select using (actif or public.is_admin());
drop policy if exists pr_admin on public.products;
create policy pr_admin on public.products for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists o_read on public.orders;
create policy o_read on public.orders for select using (user_id = auth.uid() or public.is_admin());
drop policy if exists o_admin on public.orders;
create policy o_admin on public.orders for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists m_read on public.messages;
create policy m_read on public.messages for select using (user_id = auth.uid() or public.is_admin());
drop policy if exists m_client_insert on public.messages;
create policy m_client_insert on public.messages for insert with check (
  user_id = auth.uid() and from_admin = false and lu = false
  and exists (select 1 from public.orders o where o.user_id = auth.uid())
);
drop policy if exists m_admin on public.messages;
create policy m_admin on public.messages for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists pd_admin on public.production;
create policy pd_admin on public.production for all using (public.is_admin()) with check (public.is_admin());

-- ---------- Fonctions métier ----------
-- Commande client : les prix sont recalculés côté serveur
create or replace function public.place_order(items jsonb, p_point text, p_date date, p_notes text)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_lignes jsonb := '[]'; v_total numeric := 0; v_id bigint; it jsonb; pr record; q int; prof record;
begin
  if auth.uid() is null then raise exception 'Connecte-toi pour commander'; end if;
  if p_point not in ('uccle','woluwe') then raise exception 'Point de retrait inconnu'; end if;
  if p_date < current_date then raise exception 'Date passée'; end if;
  select * into prof from profiles where id = auth.uid();
  for it in select * from jsonb_array_elements(items) loop
    q := (it->>'qte')::int;
    if q is null or q <= 0 then continue; end if;
    if q > 50 then raise exception 'Quantité trop grande'; end if;
    select * into pr from products where id = (it->>'pid')::uuid and actif;
    if not found then raise exception 'Produit indisponible'; end if;
    v_lignes := v_lignes || jsonb_build_object('pid', pr.id, 'nom', pr.nom, 'prix', pr.prix, 'qte', q);
    v_total := v_total + pr.prix * q;
  end loop;
  if jsonb_array_length(v_lignes) = 0 then raise exception 'Panier vide'; end if;
  insert into orders (user_id, client_nom, client_tel, lignes, total, point, date_retrait, notes, source, paiement)
  values (auth.uid(), prof.username, prof.tel, v_lignes, v_total, p_point, p_date, left(coalesce(p_notes,''), 500), 'en_ligne', 'cash')
  returning id into v_id;
  return v_id;
end $$;

-- Le client peut annuler tant que la commande n'est pas préparée
create or replace function public.cancel_my_order(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  update orders set statut = 'annulee'
  where id = p_id and user_id = auth.uid() and statut = 'a_preparer';
  if not found then raise exception 'Commande impossible à annuler'; end if;
end $$;

-- Ajustement de stock atomique (admin)
create or replace function public.adjust_stock(p_id uuid, p_delta int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé'; end if;
  update products set stock = stock + p_delta where id = p_id;
end $$;

-- Changement de statut : le stock baisse au passage en "livree" et revient si on en sort (admin)
create or replace function public.set_order_status(p_id bigint, p_statut text) returns void
language plpgsql security definer set search_path = public as $$
declare o record; l jsonb; s int;
begin
  if not public.is_admin() then raise exception 'Réservé'; end if;
  select * into o from orders where id = p_id for update;
  if not found then return; end if;
  s := 0;
  if p_statut = 'livree' and not o.stock_deduit then s := -1;
  elsif p_statut <> 'livree' and o.stock_deduit then s := 1; end if;
  if s <> 0 then
    for l in select * from jsonb_array_elements(o.lignes) loop
      update products set stock = stock + s * (l->>'qte')::int where id = (l->>'pid')::uuid;
    end loop;
  end if;
  update orders set statut = p_statut, stock_deduit = (p_statut = 'livree') where id = p_id;
end $$;

revoke execute on function public.adjust_stock(uuid,int) from anon;
revoke execute on function public.set_order_status(bigint,text) from anon;
revoke execute on function public.place_order(jsonb,text,date,text) from anon;
revoke execute on function public.cancel_my_order(bigint) from anon;

-- ---------- Temps réel (chat et nouvelles commandes) ----------
do $$ begin
  alter publication supabase_realtime add table public.messages;
exception when others then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.orders;
exception when others then null; end $$;

-- ---------- Accès aux tables et fonctions (la sécurité RLS s'applique toujours) ----------
grant usage on schema public to anon, authenticated;
grant select on public.products to anon, authenticated;
grant insert, update, delete on public.products to authenticated;
grant select, insert, update, delete on public.orders, public.messages, public.production to authenticated;
grant select on public.profiles to authenticated;
grant usage, select on all sequences in schema public to authenticated;
revoke execute on function public.adjust_stock(uuid,int) from public;
revoke execute on function public.set_order_status(bigint,text) from public;
revoke execute on function public.place_order(jsonb,text,date,text) from public;
revoke execute on function public.cancel_my_order(bigint) from public;
grant execute on function public.adjust_stock(uuid,int) to authenticated;
grant execute on function public.set_order_status(bigint,text) to authenticated;
grant execute on function public.place_order(jsonb,text,date,text) to authenticated;
grant execute on function public.cancel_my_order(bigint) to authenticated;

-- ---------- Bucket photos (gestion) ----------
insert into storage.buckets (id, name, public) values ('photos','photos',true) on conflict (id) do nothing;
drop policy if exists photos_admin on storage.objects;
create policy photos_admin on storage.objects for all to authenticated
  using (bucket_id = 'photos' and public.is_admin()) with check (bucket_id = 'photos' and public.is_admin());

-- ---------- Stock disponible et prochain batch ----------
alter table public.orders add column if not exists prochain_batch integer not null default 0;

create or replace function public.available_stock()
returns table(pid uuid, dispo integer) language sql stable security definer set search_path = public as $$
  select p.id, (p.stock - coalesce((select sum((l->>'qte')::int) from orders o, jsonb_array_elements(o.lignes) l
    where o.statut in ('a_preparer','prete') and (l->>'pid')::uuid = p.id), 0))::int
  from products p where p.actif
$$;
grant execute on function public.available_stock() to anon, authenticated;

create or replace function public.place_order(items jsonb, p_point text, p_date date, p_notes text)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_lignes jsonb := '[]'; v_total numeric := 0; v_id bigint; it jsonb; pr record; q int; prof record; v_next int := 0; v_av int;
begin
  if auth.uid() is null then raise exception 'Connecte-toi pour commander'; end if;
  if p_point not in ('uccle','woluwe') then raise exception 'Point de retrait inconnu'; end if;
  if p_date < current_date then raise exception 'Date passée'; end if;
  select * into prof from profiles where id = auth.uid();
  for it in select * from jsonb_array_elements(items) loop
    q := (it->>'qte')::int;
    if q is null or q <= 0 then continue; end if;
    if q > 50 then raise exception 'Quantité trop grande'; end if;
    select * into pr from products where id = (it->>'pid')::uuid and actif;
    if not found then raise exception 'Produit indisponible'; end if;
    select dispo into v_av from available_stock() where pid = pr.id;
    v_next := v_next + greatest(0, q - greatest(0, coalesce(v_av,0)));
    v_lignes := v_lignes || jsonb_build_object('pid', pr.id, 'nom', pr.nom, 'prix', pr.prix, 'qte', q);
    v_total := v_total + pr.prix * q;
  end loop;
  if jsonb_array_length(v_lignes) = 0 then raise exception 'Panier vide'; end if;
  insert into orders (user_id, client_nom, client_tel, lignes, total, point, date_retrait, notes, source, paiement, prochain_batch)
  values (auth.uid(), prof.username, prof.tel, v_lignes, v_total, p_point, p_date, left(coalesce(p_notes,''), 500), 'en_ligne', 'cash', v_next)
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.place_order(jsonb,text,date,text) from public, anon;
grant execute on function public.place_order(jsonb,text,date,text) to authenticated;


-- ---------- APRÈS t'être inscrit sur le site avec ton pseudo ----------
-- Remplace TONPSEUDO puis lance seulement cette ligne pour devenir administrateur :
-- update public.profiles set is_admin = true where username = 'tonpseudo';
