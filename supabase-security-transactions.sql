-- Pendura Aí — segurança multiusuário e operações financeiras atômicas
-- Execute este arquivo inteiro no SQL Editor do Supabase.
-- A transação garante que, se qualquer etapa falhar, nenhuma alteração seja aplicada.

begin;

-- Interrompe antes de alterar políticas caso o banco não tenha o esquema esperado.
do $$
declare
  missing_columns text;
begin
  select string_agg(format('%s.%s', expected.table_name, expected.column_name), ', ')
    into missing_columns
  from (
    values
      ('clients','code'), ('clients','name'), ('clients','phone'), ('clients','user_id'),
      ('products','code'), ('products','name'), ('products','price'), ('products','cost'), ('products','user_id'),
      ('movements','id'), ('movements','type'), ('movements','client_code'), ('movements','client_name'),
      ('movements','product_code'), ('movements','product_name'), ('movements','qty'),
      ('movements','unit_price'), ('movements','total'), ('movements','date'), ('movements','obs'), ('movements','user_id'),
      ('orders','id'), ('orders','client_code'), ('orders','client_name'), ('orders','total'),
      ('orders','delivery_date'), ('orders','obs'), ('orders','status'), ('orders','user_id'),
      ('order_items','id'), ('order_items','order_id'), ('order_items','product_code'),
      ('order_items','product_name'), ('order_items','qty'), ('order_items','unit_price'), ('order_items','total'),
      ('profiles','id'), ('profiles','email'), ('profiles','name'), ('profiles','is_approved'),
      ('profiles','is_admin'), ('profiles','deactivated_at')
  ) as expected(table_name, column_name)
  where not exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name = expected.table_name
      and c.column_name = expected.column_name
  );

  if missing_columns is not null then
    raise exception 'Migração cancelada. Colunas ausentes: %', missing_columns;
  end if;
end;
$$;

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create or replace function private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and p.is_admin is true
  );
$$;

create or replace function private.is_active_user()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and (p.is_approved is true or p.is_admin is true)
  );
$$;

revoke all on function private.is_admin() from public, anon;
revoke all on function private.is_active_user() from public, anon;
grant execute on function private.is_admin() to authenticated;
grant execute on function private.is_active_user() to authenticated;

-- Endurece as duas funções legadas já usadas pelo cadastro e pelas políticas
-- antigas. Todas as relações são qualificadas porque o search_path fica vazio.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, name, is_approved, is_admin)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'name', new.email),
    false,
    false
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select p.is_admin
    from public.profiles p
    where p.id = (select auth.uid())
      and p.is_approved is true
  ), false);
$$;

revoke all on function public.handle_new_user() from public, anon;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- Índices usados pelas políticas e pelos cálculos de saldo.
create index if not exists clients_user_id_idx on public.clients(user_id);
create index if not exists products_user_id_idx on public.products(user_id);
create index if not exists movements_user_id_idx on public.movements(user_id);
create index if not exists movements_client_balance_idx on public.movements(user_id, client_code, type);
create index if not exists orders_user_id_idx on public.orders(user_id);
create index if not exists order_items_order_id_idx on public.order_items(order_id);

-- Converte encomendas antigas de um único produto para order_items, quando essas
-- colunas legadas ainda existem. SQL dinâmico mantém a migração compatível.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'orders' and column_name = 'product_code'
  ) and exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'orders' and column_name = 'product_name'
  ) and exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'orders' and column_name = 'qty'
  ) and exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'orders' and column_name = 'unit_price'
  ) then
    execute $legacy$
      insert into public.order_items
        (id, order_id, product_code, product_name, qty, unit_price, total)
      select
        'legacy-' || o.id,
        o.id,
        o.product_code,
        o.product_name,
        coalesce(o.qty, 1),
        coalesce(o.unit_price, o.total),
        o.total
      from public.orders o
      where o.product_code is not null
        and not exists (
          select 1 from public.order_items oi where oi.order_id = o.id
        )
      on conflict (id) do nothing
    $legacy$;
  end if;
end;
$$;

-- Remove apenas as versões desta migração antes de recriá-las.
drop function if exists public.pendura_backend_version();
drop function if exists public.pendura_add_sale(text, date, text, jsonb);
drop function if exists public.pendura_add_payment(text, text, numeric, date, text);
drop function if exists public.pendura_delete_client(text);
drop function if exists public.pendura_create_order(text, text, date, text, jsonb);
drop function if exists public.pendura_update_order(text, text, date, text, jsonb);
drop function if exists public.pendura_set_order_status(text, text);
drop function if exists public.pendura_deliver_order(text, date, text);
drop function if exists public.pendura_delete_order(text);
drop function if exists public.pendura_admin_delete_user(uuid);
drop function if exists public.pendura_admin_unowned_count();
drop function if exists public.pendura_admin_claim_unowned();

create function public.pendura_backend_version()
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select '2026-07-22.1'::text;
$$;

create function public.pendura_add_sale(
  p_client_code text,
  p_date date,
  p_obs text,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_client_name text;
  v_item_count integer;
  v_distinct_ids integer;
  v_total numeric;
begin
  if v_uid is null or not private.is_active_user() then
    raise exception 'Acesso negado.' using errcode = '42501';
  end if;
  if coalesce(jsonb_typeof(p_items), '') <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Adicione ao menos um item válido.' using errcode = '22023';
  end if;

  select c.name into v_client_name
  from public.clients c
  where c.code = p_client_code and c.user_id = v_uid
  for update;
  if not found then
    raise exception 'Cliente não encontrado.' using errcode = 'P0002';
  end if;

  with input_items as (
    select i.id, i.product_code, i.qty, i.unit_price
    from jsonb_to_recordset(p_items)
      as i(id text, product_code text, qty integer, unit_price numeric)
  )
  select count(*), count(distinct i.id), coalesce(sum(i.qty * i.unit_price), 0)
    into v_item_count, v_distinct_ids, v_total
  from input_items i
  join public.products p
    on p.code = i.product_code and p.user_id = v_uid
  where nullif(i.id, '') is not null
    and i.qty > 0
    and i.unit_price >= 0;

  if v_item_count <> jsonb_array_length(p_items) or v_distinct_ids <> v_item_count then
    raise exception 'Há item inválido ou repetido na venda.' using errcode = '22023';
  end if;

  insert into public.movements
    (id, type, client_code, client_name, product_code, product_name,
     qty, unit_price, total, date, obs, user_id)
  select
    i.id, 'venda', p_client_code, v_client_name, i.product_code, p.name,
    i.qty, i.unit_price, i.qty * i.unit_price, coalesce(p_date, current_date),
    coalesce(p_obs, ''), v_uid
  from jsonb_to_recordset(p_items)
    as i(id text, product_code text, qty integer, unit_price numeric)
  join public.products p
    on p.code = i.product_code and p.user_id = v_uid;

  return jsonb_build_object('items', v_item_count, 'total', v_total);
end;
$$;

create function public.pendura_add_payment(
  p_id text,
  p_client_code text,
  p_value numeric,
  p_date date,
  p_obs text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_client_name text;
  v_debt numeric;
begin
  if v_uid is null or not private.is_active_user() then
    raise exception 'Acesso negado.' using errcode = '42501';
  end if;
  if nullif(p_id, '') is null or p_value is null or p_value <= 0 then
    raise exception 'Informe um valor válido.' using errcode = '22023';
  end if;

  select c.name into v_client_name
  from public.clients c
  where c.code = p_client_code and c.user_id = v_uid
  for update;
  if not found then
    raise exception 'Cliente não encontrado.' using errcode = 'P0002';
  end if;

  select coalesce(sum(
    case m.type
      when 'venda' then m.total
      when 'pagamento' then -m.total
      else 0
    end
  ), 0)
  into v_debt
  from public.movements m
  where m.user_id = v_uid and m.client_code = p_client_code;

  if v_debt <= 0 then
    raise exception 'Este cliente não possui dívida.' using errcode = 'P0001';
  end if;
  if p_value > v_debt + 0.009 then
    raise exception 'Valor maior que o débito atual.' using errcode = '22003';
  end if;

  insert into public.movements
    (id, type, client_code, client_name, product_code, product_name,
     qty, unit_price, total, date, obs, user_id)
  values
    (p_id, 'pagamento', p_client_code, v_client_name, '—', 'Pagamento recebido',
     1, p_value, p_value, coalesce(p_date, current_date), coalesce(p_obs, ''), v_uid);

  return jsonb_build_object('paid', p_value, 'debt_after', greatest(v_debt - p_value, 0));
end;
$$;

create function public.pendura_delete_client(p_client_code text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_debt numeric;
begin
  if v_uid is null or not private.is_active_user() then
    raise exception 'Acesso negado.' using errcode = '42501';
  end if;

  perform 1 from public.clients c
  where c.code = p_client_code and c.user_id = v_uid
  for update;
  if not found then
    raise exception 'Cliente não encontrado.' using errcode = 'P0002';
  end if;

  select coalesce(sum(
    case m.type when 'venda' then m.total when 'pagamento' then -m.total else 0 end
  ), 0)
  into v_debt
  from public.movements m
  where m.user_id = v_uid and m.client_code = p_client_code;

  if v_debt > 0.009 then
    raise exception 'Não é possível excluir cliente com dívida em aberto.' using errcode = '23514';
  end if;

  delete from public.clients c
  where c.code = p_client_code and c.user_id = v_uid;
  return true;
end;
$$;

create function public.pendura_create_order(
  p_order_id text,
  p_client_code text,
  p_delivery_date date,
  p_obs text,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_client_name text;
  v_item_count integer;
  v_distinct_ids integer;
  v_total numeric;
begin
  if v_uid is null or not private.is_active_user() then
    raise exception 'Acesso negado.' using errcode = '42501';
  end if;
  if nullif(p_order_id, '') is null or coalesce(jsonb_typeof(p_items), '') <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'Encomenda inválida.' using errcode = '22023';
  end if;

  select c.name into v_client_name
  from public.clients c
  where c.code = p_client_code and c.user_id = v_uid
  for update;
  if not found then
    raise exception 'Cliente não encontrado.' using errcode = 'P0002';
  end if;

  with input_items as (
    select i.id, i.product_code, i.qty, i.unit_price
    from jsonb_to_recordset(p_items)
      as i(id text, product_code text, qty integer, unit_price numeric)
  )
  select count(*), count(distinct i.id), coalesce(sum(i.qty * i.unit_price), 0)
    into v_item_count, v_distinct_ids, v_total
  from input_items i
  join public.products p
    on p.code = i.product_code and p.user_id = v_uid
  where nullif(i.id, '') is not null and i.qty > 0 and i.unit_price >= 0;

  if v_item_count <> jsonb_array_length(p_items) or v_distinct_ids <> v_item_count then
    raise exception 'Há item inválido ou repetido na encomenda.' using errcode = '22023';
  end if;

  insert into public.orders
    (id, client_code, client_name, total, delivery_date, obs, status, user_id)
  values
    (p_order_id, p_client_code, v_client_name, v_total, p_delivery_date,
     coalesce(p_obs, ''), 'pendente', v_uid);

  insert into public.order_items
    (id, order_id, product_code, product_name, qty, unit_price, total)
  select
    i.id, p_order_id, i.product_code, p.name, i.qty, i.unit_price, i.qty * i.unit_price
  from jsonb_to_recordset(p_items)
    as i(id text, product_code text, qty integer, unit_price numeric)
  join public.products p
    on p.code = i.product_code and p.user_id = v_uid;

  return jsonb_build_object('order_id', p_order_id, 'items', v_item_count, 'total', v_total);
end;
$$;

create function public.pendura_update_order(
  p_order_id text,
  p_client_code text,
  p_delivery_date date,
  p_obs text,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_client_name text;
  v_status text;
  v_item_count integer;
  v_distinct_ids integer;
  v_total numeric;
begin
  if v_uid is null or not private.is_active_user() then
    raise exception 'Acesso negado.' using errcode = '42501';
  end if;
  if coalesce(jsonb_typeof(p_items), '') <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Adicione ao menos um item válido.' using errcode = '22023';
  end if;

  select o.status into v_status
  from public.orders o
  where o.id = p_order_id and o.user_id = v_uid
  for update;
  if not found then
    raise exception 'Encomenda não encontrada.' using errcode = 'P0002';
  end if;
  if v_status = 'entregue' then
    raise exception 'Encomenda entregue não pode ser editada.' using errcode = '23514';
  end if;

  select c.name into v_client_name
  from public.clients c
  where c.code = p_client_code and c.user_id = v_uid
  for update;
  if not found then
    raise exception 'Cliente não encontrado.' using errcode = 'P0002';
  end if;

  with input_items as (
    select i.id, i.product_code, i.qty, i.unit_price
    from jsonb_to_recordset(p_items)
      as i(id text, product_code text, qty integer, unit_price numeric)
  )
  select count(*), count(distinct i.id), coalesce(sum(i.qty * i.unit_price), 0)
    into v_item_count, v_distinct_ids, v_total
  from input_items i
  join public.products p
    on p.code = i.product_code and p.user_id = v_uid
  where nullif(i.id, '') is not null and i.qty > 0 and i.unit_price >= 0;

  if v_item_count <> jsonb_array_length(p_items) or v_distinct_ids <> v_item_count then
    raise exception 'Há item inválido ou repetido na encomenda.' using errcode = '22023';
  end if;

  update public.orders o
  set client_code = p_client_code,
      client_name = v_client_name,
      total = v_total,
      delivery_date = p_delivery_date,
      obs = coalesce(p_obs, '')
  where o.id = p_order_id and o.user_id = v_uid;

  delete from public.order_items oi where oi.order_id = p_order_id;

  insert into public.order_items
    (id, order_id, product_code, product_name, qty, unit_price, total)
  select
    i.id, p_order_id, i.product_code, p.name, i.qty, i.unit_price, i.qty * i.unit_price
  from jsonb_to_recordset(p_items)
    as i(id text, product_code text, qty integer, unit_price numeric)
  join public.products p
    on p.code = i.product_code and p.user_id = v_uid;

  return jsonb_build_object('order_id', p_order_id, 'items', v_item_count, 'total', v_total);
end;
$$;

create function public.pendura_set_order_status(p_order_id text, p_status text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_current_status text;
begin
  if v_uid is null or not private.is_active_user() then
    raise exception 'Acesso negado.' using errcode = '42501';
  end if;
  if p_status is null or p_status not in ('pendente', 'pronto') then
    raise exception 'Status inválido.' using errcode = '22023';
  end if;

  select o.status into v_current_status
  from public.orders o
  where o.id = p_order_id and o.user_id = v_uid
  for update;
  if not found then
    raise exception 'Encomenda não encontrada.' using errcode = 'P0002';
  end if;
  if v_current_status = 'entregue' then
    raise exception 'Encomenda já entregue.' using errcode = '23514';
  end if;

  update public.orders o set status = p_status
  where o.id = p_order_id and o.user_id = v_uid;
  return p_status;
end;
$$;

create function public.pendura_deliver_order(p_order_id text, p_date date, p_obs text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_order public.orders%rowtype;
  v_item_count integer;
  v_prefix text;
  v_movement_obs text;
begin
  if v_uid is null or not private.is_active_user() then
    raise exception 'Acesso negado.' using errcode = '42501';
  end if;

  select o.* into v_order
  from public.orders o
  where o.id = p_order_id and o.user_id = v_uid
  for update;
  if not found then
    raise exception 'Encomenda não encontrada.' using errcode = 'P0002';
  end if;
  if v_order.status = 'entregue' then
    raise exception 'Esta encomenda já foi entregue.' using errcode = '23514';
  end if;

  perform 1 from public.clients c
  where c.code = v_order.client_code and c.user_id = v_uid
  for update;
  if not found then
    raise exception 'Cliente da encomenda não encontrado.' using errcode = 'P0002';
  end if;

  select count(*) into v_item_count
  from public.order_items oi where oi.order_id = p_order_id;
  if v_item_count = 0 then
    raise exception 'Encomenda sem itens. Edite-a antes de entregar.' using errcode = '23514';
  end if;

  v_prefix := 'MO-' || coalesce(nullif(regexp_replace(p_order_id, '[^a-zA-Z0-9_-]', '', 'g'), ''), 'order') || '-';
  v_movement_obs := concat_ws(' | ', 'Encomenda entregue', nullif(v_order.obs, ''), nullif(p_obs, ''));

  -- Limpa apenas lançamentos órfãos de uma tentativa anterior que não marcou a entrega.
  delete from public.movements m
  where m.user_id = v_uid
    and left(m.id, length(v_prefix)) = v_prefix;

  insert into public.movements
    (id, type, client_code, client_name, product_code, product_name,
     qty, unit_price, total, date, obs, user_id)
  select
    v_prefix || ((row_number() over (order by oi.id)) - 1)::text,
    'venda', v_order.client_code, v_order.client_name,
    oi.product_code, oi.product_name, oi.qty, oi.unit_price, oi.total,
    coalesce(p_date, current_date), v_movement_obs, v_uid
  from public.order_items oi
  where oi.order_id = p_order_id;

  update public.orders o set status = 'entregue'
  where o.id = p_order_id and o.user_id = v_uid;

  return jsonb_build_object('order_id', p_order_id, 'items', v_item_count, 'total', v_order.total);
end;
$$;

create function public.pendura_delete_order(p_order_id text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null or not private.is_active_user() then
    raise exception 'Acesso negado.' using errcode = '42501';
  end if;

  perform 1 from public.orders o
  where o.id = p_order_id and o.user_id = v_uid
  for update;
  if not found then
    raise exception 'Encomenda não encontrada.' using errcode = 'P0002';
  end if;

  delete from public.order_items oi where oi.order_id = p_order_id;
  delete from public.orders o where o.id = p_order_id and o.user_id = v_uid;
  return true;
end;
$$;

create function public.pendura_admin_delete_user(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_orders integer := 0;
  v_movements integer := 0;
  v_products integer := 0;
  v_clients integer := 0;
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'Acesso restrito ao administrador.' using errcode = '42501';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'O administrador não pode excluir a própria conta.' using errcode = '23514';
  end if;

  delete from public.order_items oi
  where exists (
    select 1 from public.orders o where o.id = oi.order_id and o.user_id = p_user_id
  );
  delete from public.orders o where o.user_id = p_user_id;
  get diagnostics v_orders = row_count;
  delete from public.movements m where m.user_id = p_user_id;
  get diagnostics v_movements = row_count;
  delete from public.products p where p.user_id = p_user_id;
  get diagnostics v_products = row_count;
  delete from public.clients c where c.user_id = p_user_id;
  get diagnostics v_clients = row_count;
  delete from public.profiles p where p.id = p_user_id;

  return jsonb_build_object(
    'orders', v_orders, 'movements', v_movements,
    'products', v_products, 'clients', v_clients
  );
end;
$$;

create function public.pendura_admin_unowned_count()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count bigint;
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'Acesso restrito ao administrador.' using errcode = '42501';
  end if;
  select count(*) into v_count from public.clients c where c.user_id is null;
  return v_count;
end;
$$;

create function public.pendura_admin_claim_unowned()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_clients integer := 0;
  v_products integer := 0;
  v_movements integer := 0;
  v_orders integer := 0;
begin
  if v_uid is null or not private.is_admin() then
    raise exception 'Acesso restrito ao administrador.' using errcode = '42501';
  end if;

  update public.clients c set user_id = v_uid where c.user_id is null;
  get diagnostics v_clients = row_count;
  update public.products p set user_id = v_uid where p.user_id is null;
  get diagnostics v_products = row_count;
  update public.movements m set user_id = v_uid where m.user_id is null;
  get diagnostics v_movements = row_count;
  update public.orders o set user_id = v_uid where o.user_id is null;
  get diagnostics v_orders = row_count;

  return jsonb_build_object(
    'clients', v_clients, 'products', v_products,
    'movements', v_movements, 'orders', v_orders
  );
end;
$$;

-- Funções RPC ficam disponíveis somente para usuários autenticados.
revoke all on function public.pendura_backend_version() from public, anon;
revoke all on function public.pendura_add_sale(text, date, text, jsonb) from public, anon;
revoke all on function public.pendura_add_payment(text, text, numeric, date, text) from public, anon;
revoke all on function public.pendura_delete_client(text) from public, anon;
revoke all on function public.pendura_create_order(text, text, date, text, jsonb) from public, anon;
revoke all on function public.pendura_update_order(text, text, date, text, jsonb) from public, anon;
revoke all on function public.pendura_set_order_status(text, text) from public, anon;
revoke all on function public.pendura_deliver_order(text, date, text) from public, anon;
revoke all on function public.pendura_delete_order(text) from public, anon;
revoke all on function public.pendura_admin_delete_user(uuid) from public, anon;
revoke all on function public.pendura_admin_unowned_count() from public, anon;
revoke all on function public.pendura_admin_claim_unowned() from public, anon;

grant execute on function public.pendura_backend_version() to authenticated;
grant execute on function public.pendura_add_sale(text, date, text, jsonb) to authenticated;
grant execute on function public.pendura_add_payment(text, text, numeric, date, text) to authenticated;
grant execute on function public.pendura_delete_client(text) to authenticated;
grant execute on function public.pendura_create_order(text, text, date, text, jsonb) to authenticated;
grant execute on function public.pendura_update_order(text, text, date, text, jsonb) to authenticated;
grant execute on function public.pendura_set_order_status(text, text) to authenticated;
grant execute on function public.pendura_deliver_order(text, date, text) to authenticated;
grant execute on function public.pendura_delete_order(text) to authenticated;
grant execute on function public.pendura_admin_delete_user(uuid) to authenticated;
grant execute on function public.pendura_admin_unowned_count() to authenticated;
grant execute on function public.pendura_admin_claim_unowned() to authenticated;

-- Substitui políticas antigas para impedir que uma regra permissiva sobreviva.
do $$
declare
  policy_row record;
begin
  for policy_row in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('clients','products','movements','orders','order_items','profiles')
  loop
    execute format('drop policy %I on %I.%I',
      policy_row.policyname, policy_row.schemaname, policy_row.tablename);
  end loop;
end;
$$;

alter table public.clients enable row level security;
alter table public.products enable row level security;
alter table public.movements enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.profiles enable row level security;

create policy clients_select_own on public.clients
for select to authenticated
using ((select private.is_active_user()) and user_id = (select auth.uid()));

create policy clients_insert_own on public.clients
for insert to authenticated
with check ((select private.is_active_user()) and user_id = (select auth.uid()));

create policy clients_update_own on public.clients
for update to authenticated
using ((select private.is_active_user()) and user_id = (select auth.uid()))
with check ((select private.is_active_user()) and user_id = (select auth.uid()));

create policy products_select_own on public.products
for select to authenticated
using ((select private.is_active_user()) and user_id = (select auth.uid()));

create policy products_insert_own on public.products
for insert to authenticated
with check ((select private.is_active_user()) and user_id = (select auth.uid()));

create policy products_update_own on public.products
for update to authenticated
using ((select private.is_active_user()) and user_id = (select auth.uid()))
with check ((select private.is_active_user()) and user_id = (select auth.uid()));

create policy products_delete_own on public.products
for delete to authenticated
using ((select private.is_active_user()) and user_id = (select auth.uid()));

create policy movements_select_own on public.movements
for select to authenticated
using ((select private.is_active_user()) and user_id = (select auth.uid()));

create policy movements_delete_own on public.movements
for delete to authenticated
using ((select private.is_active_user()) and user_id = (select auth.uid()));

create policy orders_select_own on public.orders
for select to authenticated
using ((select private.is_active_user()) and user_id = (select auth.uid()));

create policy order_items_select_own on public.order_items
for select to authenticated
using (
  (select private.is_active_user())
  and exists (
    select 1 from public.orders o
    where o.id = order_items.order_id
      and o.user_id = (select auth.uid())
  )
);

-- O próprio usuário precisa ler o perfil mesmo enquanto aguarda aprovação.
create policy profiles_select_self_or_admin on public.profiles
for select to authenticated
using (id = (select auth.uid()) or (select private.is_admin()));

create policy profiles_update_admin on public.profiles
for update to authenticated
using ((select private.is_admin()))
with check ((select private.is_admin()));

commit;
