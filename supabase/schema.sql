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

-- ===== v3 : gestion des admins + chiffres publics =====
create or replace function public.set_admin(p_username text, p_admin boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé'; end if;
  if not p_admin and lower(p_username) = (select username from public.profiles where id = auth.uid()) then
    raise exception 'Tu ne peux pas retirer tes propres droits';
  end if;
  update public.profiles set is_admin = p_admin where username = lower(p_username);
  if not found then raise exception 'Pseudo introuvable'; end if;
end $$;
revoke all on function public.set_admin(text, boolean) from public, anon;
grant execute on function public.set_admin(text, boolean) to authenticated;

-- chiffres agrégés (aucune donnée personnelle) pour la page Story
create or replace function public.public_stats() returns table(boites bigint, commandes bigint, clients bigint, fideles bigint)
language sql stable security definer set search_path = public as $$
  with o as (select coalesce(user_id::text, lower(trim(client_nom))) as c, lignes from public.orders where statut = 'livree'),
  per as (select c, count(*) n from o group by c)
  select (select coalesce(sum((l->>'qte')::int),0) from o, jsonb_array_elements(o.lignes) l),
         (select count(*) from o), (select count(*) from per), (select count(*) from per where n >= 2);
$$;
grant execute on function public.public_stats() to anon, authenticated;
-- ===== v4 : contenu du site éditable + codes promo =====
create table if not exists public.site_settings (
  id text primary key default 'main',
  data jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
alter table public.site_settings enable row level security;
drop policy if exists ss_read on public.site_settings;
create policy ss_read on public.site_settings for select using (true);
drop policy if exists ss_admin on public.site_settings;
create policy ss_admin on public.site_settings for all using (public.is_admin()) with check (public.is_admin());
grant select on public.site_settings to anon, authenticated;
grant insert, update on public.site_settings to authenticated;
insert into public.site_settings (id, data) values ('main', '{}') on conflict do nothing;

create table if not exists public.promo_codes (
  code text primary key check (code = upper(code) and length(code) between 3 and 20),
  type text not null default 'pct' check (type in ('pct','eur')),
  valeur numeric(10,2) not null check (valeur > 0),
  actif boolean not null default true,
  expire date,
  max_uses int,
  uses int not null default 0,
  created_at timestamptz not null default now()
);
alter table public.promo_codes enable row level security;
drop policy if exists pc_admin on public.promo_codes;
create policy pc_admin on public.promo_codes for all using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.promo_codes to authenticated;

alter table public.orders add column if not exists promo_code text;
alter table public.orders add column if not exists remise numeric(10,2) not null default 0;

create or replace function public.check_promo(p_code text) returns table(code text, type text, valeur numeric)
language sql stable security definer set search_path = public as $$
  select c.code, c.type, c.valeur from promo_codes c
  where c.code = upper(trim(p_code)) and c.actif
    and (c.expire is null or c.expire >= current_date)
    and (c.max_uses is null or c.uses < c.max_uses);
$$;
grant execute on function public.check_promo(text) to anon, authenticated;

create or replace function public.place_order(items jsonb, p_point text, p_date date, p_notes text, p_code text)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_lignes jsonb := '[]'; v_total numeric := 0; v_id bigint; it jsonb; pr record; q int; prof record; v_next int := 0; v_av int;
  pc record; v_remise numeric := 0; v_code text := null;
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
  if coalesce(trim(p_code),'') <> '' then
    select * into pc from check_promo(p_code);
    if not found then raise exception 'Code promo invalide ou expiré'; end if;
    v_code := pc.code;
    v_remise := case when pc.type = 'pct' then round(v_total * least(pc.valeur,100) / 100, 2) else least(pc.valeur, v_total) end;
    update promo_codes set uses = uses + 1 where code = pc.code;
  end if;
  insert into orders (user_id, client_nom, client_tel, lignes, total, point, date_retrait, notes, source, paiement, prochain_batch, promo_code, remise)
  values (auth.uid(), prof.username, prof.tel, v_lignes, v_total - v_remise, p_point, p_date, left(coalesce(p_notes,''), 500), 'en_ligne', 'cash', v_next, v_code, v_remise)
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.place_order(jsonb,text,date,text,text) from public, anon;
grant execute on function public.place_order(jsonb,text,date,text,text) to authenticated;
select 'ok' as v4;
-- ===== v5 : coûts de revient et dépenses (réservé aux admins) =====
create table if not exists public.admin_settings (
  id text primary key,
  data jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
alter table public.admin_settings enable row level security;
drop policy if exists as_admin on public.admin_settings;
create policy as_admin on public.admin_settings for all using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.admin_settings to authenticated;

create table if not exists public.depenses (
  id bigint generated always as identity primary key,
  date date not null default current_date,
  description text not null default '',
  montant numeric(10,2) not null default 0,
  categorie text not null default 'ingredients',
  qui text default '',
  created_at timestamptz not null default now()
);
alter table public.depenses enable row level security;
drop policy if exists dp_admin on public.depenses;
create policy dp_admin on public.depenses for all using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.depenses to authenticated;
grant usage, select on all sequences in schema public to authenticated;
select 'ok' as v5;

-- v6 : durcissement sécurité (audit nov. 2026)
revoke truncate, trigger, references on all tables in schema public from anon, authenticated;
drop function if exists public.place_order(jsonb, text, date, text);

-- limite anti-abus : 5 commandes en ligne ouvertes max par client
create or replace function public.guard_order() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.source = 'en_ligne' and new.user_id is not null and not public.is_admin() then
    if (select count(*) from public.orders where user_id = new.user_id and statut in ('a_preparer','prete')) >= 5 then
      raise exception 'Trop de commandes en cours. Écris-nous par le chat.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists orders_guard on public.orders;
create trigger orders_guard before insert on public.orders for each row execute function public.guard_order();

-- limite anti-spam : 10 messages client par 10 minutes
create or replace function public.guard_message() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not new.from_admin and not public.is_admin() then
    if (select count(*) from public.messages where user_id = new.user_id and not from_admin and created_at > now() - interval '10 minutes') >= 10 then
      raise exception 'Trop de messages, réessaie dans quelques minutes.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists messages_guard on public.messages;
create trigger messages_guard before insert on public.messages for each row execute function public.guard_message();

-- pseudo valide même si quelqu'un passe à côté du site
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare u text := lower(trim(coalesce(new.raw_user_meta_data->>'username','')));
begin
  if u !~ '^[a-z0-9._-]{3,20}$' then raise exception 'Pseudo invalide'; end if;
  insert into public.profiles (id, username, tel)
  values (new.id, u, left(coalesce(new.raw_user_meta_data->>'tel',''), 30));
  return new;
end $$;

-- v7 : commande sans compte (invité)
create or replace function public.place_guest_order(items jsonb, p_point text, p_date date, p_notes text, p_code text, p_nom text, p_tel text, p_hp text default '')
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_lignes jsonb := '[]'; v_total numeric := 0; v_id bigint; it jsonb; pr record; q int; v_next int := 0; v_av int;
  pc record; v_remise numeric := 0; v_code text := null; v_nom text; v_tel text; v_digits text;
begin
  if coalesce(p_hp,'') <> '' then raise exception 'Une erreur est survenue.'; end if;
  v_nom := left(regexp_replace(trim(coalesce(p_nom,'')), '\s+', ' ', 'g'), 40);
  v_tel := left(trim(coalesce(p_tel,'')), 25);
  v_digits := regexp_replace(v_tel, '\D', '', 'g');
  if char_length(v_nom) < 2 or v_tel = '' then raise exception 'Indique ton nom et ton téléphone.'; end if;
  if v_tel !~ '^\+?[0-9 ./()-]{8,25}$' or char_length(v_digits) not between 8 and 15 then raise exception 'Numéro de téléphone invalide.'; end if;
  if p_point not in ('uccle','woluwe') then raise exception 'Point de retrait inconnu'; end if;
  if p_date is null or p_date < current_date then raise exception 'Date passée'; end if;
  if (select count(*) from orders where user_id is null and source = 'en_ligne' and statut in ('a_preparer','prete')
        and regexp_replace(coalesce(client_tel,''), '\D', '', 'g') = v_digits) >= 3 then
    raise exception 'Trop de commandes en cours pour ce numéro. Contacte-nous sur Instagram.';
  end if;
  if (select count(*) from orders where user_id is null and source = 'en_ligne' and created_at > now() - interval '1 hour') >= 15 then
    raise exception 'Beaucoup de commandes en ce moment, réessaie dans un instant.';
  end if;
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
  if coalesce(trim(p_code),'') <> '' then
    select * into pc from check_promo(p_code);
    if not found then raise exception 'Code promo invalide ou expiré'; end if;
    v_code := pc.code;
    v_remise := case when pc.type = 'pct' then round(v_total * least(pc.valeur,100) / 100, 2) else least(pc.valeur, v_total) end;
    update promo_codes set uses = uses + 1 where code = pc.code;
  end if;
  insert into orders (user_id, client_nom, client_tel, lignes, total, point, date_retrait, notes, source, paiement, prochain_batch, promo_code, remise)
  values (null, v_nom, v_tel, v_lignes, v_total - v_remise, p_point, p_date, left(coalesce(p_notes,''), 500), 'en_ligne', 'cash', v_next, v_code, v_remise)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.place_guest_order(jsonb, text, date, text, text, text, text, text) from public;
grant execute on function public.place_guest_order(jsonb, text, date, text, text, text, text, text) to anon, authenticated;

-- v8 : interrupteur commande sans compte (site_settings.data.guest)
create or replace function public.place_guest_order(items jsonb, p_point text, p_date date, p_notes text, p_code text, p_nom text, p_tel text, p_hp text default '')
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_lignes jsonb := '[]'; v_total numeric := 0; v_id bigint; it jsonb; pr record; q int; v_next int := 0; v_av int;
  pc record; v_remise numeric := 0; v_code text := null; v_nom text; v_tel text; v_digits text;
begin
  if coalesce(p_hp,'') <> '' then raise exception 'Une erreur est survenue.'; end if;
  if exists (select 1 from site_settings where id = 'main' and data->>'guest' = 'false') then
    raise exception 'Commande sans compte désactivée. Connecte-toi pour commander.';
  end if;
  v_nom := left(regexp_replace(trim(coalesce(p_nom,'')), '\s+', ' ', 'g'), 40);
  v_tel := left(trim(coalesce(p_tel,'')), 25);
  v_digits := regexp_replace(v_tel, '\D', '', 'g');
  if char_length(v_nom) < 2 or v_tel = '' then raise exception 'Indique ton nom et ton téléphone.'; end if;
  if v_tel !~ '^\+?[0-9 ./()-]{8,25}$' or char_length(v_digits) not between 8 and 15 then raise exception 'Numéro de téléphone invalide.'; end if;
  if p_point not in ('uccle','woluwe') then raise exception 'Point de retrait inconnu'; end if;
  if p_date is null or p_date < current_date then raise exception 'Date passée'; end if;
  if (select count(*) from orders where user_id is null and source = 'en_ligne' and statut in ('a_preparer','prete')
        and regexp_replace(coalesce(client_tel,''), '\D', '', 'g') = v_digits) >= 3 then
    raise exception 'Trop de commandes en cours pour ce numéro. Contacte-nous sur Instagram.';
  end if;
  if (select count(*) from orders where user_id is null and source = 'en_ligne' and created_at > now() - interval '1 hour') >= 15 then
    raise exception 'Beaucoup de commandes en ce moment, réessaie dans un instant.';
  end if;
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
  if coalesce(trim(p_code),'') <> '' then
    select * into pc from check_promo(p_code);
    if not found then raise exception 'Code promo invalide ou expiré'; end if;
    v_code := pc.code;
    v_remise := case when pc.type = 'pct' then round(v_total * least(pc.valeur,100) / 100, 2) else least(pc.valeur, v_total) end;
    update promo_codes set uses = uses + 1 where code = pc.code;
  end if;
  insert into orders (user_id, client_nom, client_tel, lignes, total, point, date_retrait, notes, source, paiement, prochain_batch, promo_code, remise)
  values (null, v_nom, v_tel, v_lignes, v_total - v_remise, p_point, p_date, left(coalesce(p_notes,''), 500), 'en_ligne', 'cash', v_next, v_code, v_remise)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.place_guest_order(jsonb, text, date, text, text, text, text, text) from public;
grant execute on function public.place_guest_order(jsonb, text, date, text, text, text, text, text) to anon, authenticated;

-- v9 : listes de prix par client + interrupteur codes promo (site_settings.data.promo)
create table if not exists public.price_lists (
  id uuid primary key default gen_random_uuid(),
  nom text not null check (length(trim(nom)) between 1 and 40),
  created_at timestamptz not null default now()
);
create table if not exists public.price_list_items (
  list_id uuid not null references public.price_lists(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  prix numeric(10,2) not null check (prix >= 0),
  primary key (list_id, product_id)
);
alter table public.price_lists enable row level security;
alter table public.price_list_items enable row level security;
drop policy if exists pl_admin on public.price_lists;
create policy pl_admin on public.price_lists for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists pli_admin on public.price_list_items;
create policy pli_admin on public.price_list_items for all using (public.is_admin()) with check (public.is_admin());
revoke all on public.price_lists, public.price_list_items from anon;
grant select, insert, update, delete on public.price_lists, public.price_list_items to authenticated;

-- le client ne peut pas changer sa liste lui-même (seul "tel" est modifiable par le client)
alter table public.profiles add column if not exists price_list_id uuid references public.price_lists(id) on delete set null;
alter table public.orders add column if not exists liste_prix text;

-- prix du client connecté (uniquement sa propre liste)
create or replace function public.my_prices() returns table(pid uuid, prix numeric, liste text)
language sql stable security definer set search_path = public as $$
  select i.product_id, i.prix, l.nom from profiles p
  join price_lists l on l.id = p.price_list_id
  join price_list_items i on i.list_id = l.id
  where p.id = auth.uid();
$$;
revoke all on function public.my_prices() from public, anon;
grant execute on function public.my_prices() to authenticated;

create or replace function public.set_price_list(p_user uuid, p_list uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé'; end if;
  update public.profiles set price_list_id = p_list where id = p_user;
  if not found then raise exception 'Client introuvable'; end if;
end $$;
revoke all on function public.set_price_list(uuid, uuid) from public, anon;
grant execute on function public.set_price_list(uuid, uuid) to authenticated;

-- codes promo désactivables depuis la gestion : plus aucun code n'est accepté
create or replace function public.check_promo(p_code text) returns table(code text, type text, valeur numeric)
language sql stable security definer set search_path = public as $$
  select c.code, c.type, c.valeur from promo_codes c
  where c.code = upper(trim(p_code)) and c.actif
    and (c.expire is null or c.expire >= current_date)
    and (c.max_uses is null or c.uses < c.max_uses)
    and not exists (select 1 from site_settings s where s.id = 'main' and s.data->>'promo' = 'false');
$$;
grant execute on function public.check_promo(text) to anon, authenticated;

-- commande client : prix de sa liste si elle en a un, sinon prix normal
create or replace function public.place_order(items jsonb, p_point text, p_date date, p_notes text, p_code text)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_lignes jsonb := '[]'; v_total numeric := 0; v_id bigint; it jsonb; pr record; q int; prof record; v_next int := 0; v_av int;
  pc record; v_remise numeric := 0; v_code text := null; v_prix numeric; v_liste text;
begin
  if auth.uid() is null then raise exception 'Connecte-toi pour commander'; end if;
  if p_point not in ('uccle','woluwe') then raise exception 'Point de retrait inconnu'; end if;
  if p_date < current_date then raise exception 'Date passée'; end if;
  select * into prof from profiles where id = auth.uid();
  select nom into v_liste from price_lists where id = prof.price_list_id;
  for it in select * from jsonb_array_elements(items) loop
    q := (it->>'qte')::int;
    if q is null or q <= 0 then continue; end if;
    if q > 50 then raise exception 'Quantité trop grande'; end if;
    select * into pr from products where id = (it->>'pid')::uuid and actif;
    if not found then raise exception 'Produit indisponible'; end if;
    select i.prix into v_prix from price_list_items i where i.list_id = prof.price_list_id and i.product_id = pr.id;
    v_prix := coalesce(v_prix, pr.prix);
    select dispo into v_av from available_stock() where pid = pr.id;
    v_next := v_next + greatest(0, q - greatest(0, coalesce(v_av,0)));
    v_lignes := v_lignes || jsonb_build_object('pid', pr.id, 'nom', pr.nom, 'prix', v_prix, 'qte', q);
    v_total := v_total + v_prix * q;
  end loop;
  if jsonb_array_length(v_lignes) = 0 then raise exception 'Panier vide'; end if;
  if coalesce(trim(p_code),'') <> '' then
    select * into pc from check_promo(p_code);
    if not found then raise exception 'Code promo invalide ou expiré'; end if;
    v_code := pc.code;
    v_remise := case when pc.type = 'pct' then round(v_total * least(pc.valeur,100) / 100, 2) else least(pc.valeur, v_total) end;
    update promo_codes set uses = uses + 1 where code = pc.code;
  end if;
  insert into orders (user_id, client_nom, client_tel, lignes, total, point, date_retrait, notes, source, paiement, prochain_batch, promo_code, remise, liste_prix)
  values (auth.uid(), prof.username, prof.tel, v_lignes, v_total - v_remise, p_point, p_date, left(coalesce(p_notes,''), 500), 'en_ligne', 'cash', v_next, v_code, v_remise, v_liste)
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.place_order(jsonb,text,date,text,text) from public, anon;
grant execute on function public.place_order(jsonb,text,date,text,text) to authenticated;
select 'ok' as v9;
