-- Pendura Aí — cancelamento auditável de movimentações
-- Execute este arquivo inteiro no SQL Editor do Supabase.

begin;

do $$
begin
  if to_regclass('public.movements') is null then
    raise exception 'Migração cancelada: tabela public.movements não encontrada.';
  end if;
end;
$$;

alter table public.movements
  add column if not exists transaction_id text,
  add column if not exists status text not null default 'ativo',
  add column if not exists canceled_at timestamptz,
  add column if not exists canceled_reason text,
  add column if not exists canceled_by uuid,
  add column if not exists source_order_id text;

-- Agrupa pagamentos individualmente, entregas pela encomenda e vendas antigas
-- pelo instante em que os itens foram gravados na mesma transação.
update public.movements m
set transaction_id = case
  when m.type = 'pagamento' then m.id
  when m.id ~ '^MO-.+-[0-9]+$' then regexp_replace(m.id, '-[0-9]+$', '')
  else 'LEGACY-' || md5(concat_ws(
    '|',
    coalesce(m.user_id::text, ''),
    coalesce(m.client_code, ''),
    coalesce(m.type, ''),
    coalesce(m.date::text, ''),
    coalesce(m.created_at::text, ''),
    coalesce(m.obs, '')
  ))
end
where m.transaction_id is null or btrim(m.transaction_id) = '';

update public.movements m
set source_order_id = o.id
from public.orders o
where m.source_order_id is null
  and m.user_id = o.user_id
  and left(m.id, length('MO-' || o.id || '-')) = 'MO-' || o.id || '-';

alter table public.movements
  alter column transaction_id set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.movements'::regclass
      and conname = 'movements_status_check'
  ) then
    alter table public.movements
      add constraint movements_status_check
      check (status in ('ativo', 'cancelado'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.movements'::regclass
      and conname = 'movements_cancel_audit_check'
  ) then
    alter table public.movements
      add constraint movements_cancel_audit_check
      check (
        (status = 'ativo' and canceled_at is null and canceled_reason is null and canceled_by is null)
        or
        (status = 'cancelado' and canceled_at is not null
          and nullif(btrim(canceled_reason), '') is not null and canceled_by is not null)
      );
  end if;
end;
$$;

create index if not exists movements_user_status_idx
  on public.movements (user_id, status);
create index if not exists movements_user_transaction_idx
  on public.movements (user_id, transaction_id);
create index if not exists movements_source_order_idx
  on public.movements (source_order_id)
  where source_order_id is not null;

create or replace function public.pendura_backend_version()
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select '2026-07-25.1'::text;
$$;

-- Nova assinatura: recebe um identificador compartilhado por todos os itens.
drop function if exists public.pendura_add_sale(text, text, date, text, jsonb);
create function public.pendura_add_sale(
  p_transaction_id text,
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
  if nullif(btrim(p_transaction_id), '') is null then
    raise exception 'Identificador da venda inválido.' using errcode = '22023';
  end if;
  if coalesce(jsonb_typeof(p_items), '') <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Adicione ao menos um item válido.' using errcode = '22023';
  end if;

  -- Retorno idempotente para uma venda já confirmada.
  select count(*), coalesce(sum(m.total), 0)
    into v_item_count, v_total
  from public.movements m
  where m.user_id = v_uid and m.transaction_id = p_transaction_id;

  if v_item_count > 0 then
    return jsonb_build_object(
      'transaction_id', p_transaction_id,
      'items', v_item_count,
      'total', v_total,
      'already_existed', true
    );
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
    (id, transaction_id, status, type, client_code, client_name,
     product_code, product_name, qty, unit_price, total, date, obs, user_id)
  select
    i.id, p_transaction_id, 'ativo', 'venda', p_client_code, v_client_name,
    i.product_code, p.name, i.qty, i.unit_price, i.qty * i.unit_price,
    coalesce(p_date, current_date), coalesce(p_obs, ''), v_uid
  from jsonb_to_recordset(p_items)
    as i(id text, product_code text, qty integer, unit_price numeric)
  join public.products p
    on p.code = i.product_code and p.user_id = v_uid;

  return jsonb_build_object(
    'transaction_id', p_transaction_id,
    'items', v_item_count,
    'total', v_total,
    'already_existed', false
  );
end;
$$;

-- Mantém clientes antigos do app funcionando durante a troca de versão.
create or replace function public.pendura_add_sale(
  p_client_code text,
  p_date date,
  p_obs text,
  p_items jsonb
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select public.pendura_add_sale(
    'COMPAT-' || md5(
      coalesce(auth.uid()::text, '') || clock_timestamp()::text || random()::text
    ),
    p_client_code,
    p_date,
    p_obs,
    p_items
  );
$$;

create or replace function public.pendura_add_payment(
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
  v_existing public.movements%rowtype;
begin
  if v_uid is null or not private.is_active_user() then
    raise exception 'Acesso negado.' using errcode = '42501';
  end if;
  if nullif(p_id, '') is null or p_value is null or p_value <= 0 then
    raise exception 'Informe um valor válido.' using errcode = '22023';
  end if;

  select m.* into v_existing
  from public.movements m
  where m.id = p_id and m.user_id = v_uid;
  if found then
    return jsonb_build_object(
      'paid', v_existing.total,
      'already_existed', true
    );
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
  where m.user_id = v_uid
    and m.client_code = p_client_code
    and m.status = 'ativo';

  if v_debt <= 0 then
    raise exception 'Este cliente não possui dívida.' using errcode = 'P0001';
  end if;
  if p_value > v_debt + 0.009 then
    raise exception 'Valor maior que o débito atual.' using errcode = '22003';
  end if;

  insert into public.movements
    (id, transaction_id, status, type, client_code, client_name,
     product_code, product_name, qty, unit_price, total, date, obs, user_id)
  values
    (p_id, p_id, 'ativo', 'pagamento', p_client_code, v_client_name,
     '—', 'Pagamento recebido', 1, p_value, p_value,
     coalesce(p_date, current_date), coalesce(p_obs, ''), v_uid);

  return jsonb_build_object(
    'paid', p_value,
    'debt_after', greatest(v_debt - p_value, 0),
    'already_existed', false
  );
end;
$$;

create or replace function public.pendura_delete_client(p_client_code text)
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
  where m.user_id = v_uid
    and m.client_code = p_client_code
    and m.status = 'ativo';

  if v_debt > 0.009 then
    raise exception 'Não é possível excluir cliente com dívida em aberto.' using errcode = '23514';
  end if;

  delete from public.clients c
  where c.code = p_client_code and c.user_id = v_uid;
  return true;
end;
$$;

create or replace function public.pendura_deliver_order(
  p_order_id text,
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
  v_order public.orders%rowtype;
  v_item_count integer;
  v_transaction_id text;
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

  v_transaction_id := 'ENTREGA-' || regexp_replace(p_order_id, '[^a-zA-Z0-9_-]', '', 'g')
    || '-' || substr(md5(clock_timestamp()::text || random()::text), 1, 12);
  v_movement_obs := concat_ws(
    ' | ', 'Encomenda entregue', nullif(v_order.obs, ''), nullif(p_obs, '')
  );

  insert into public.movements
    (id, transaction_id, status, source_order_id, type, client_code, client_name,
     product_code, product_name, qty, unit_price, total, date, obs, user_id)
  select
    v_transaction_id || '-' || ((row_number() over (order by oi.id)) - 1)::text,
    v_transaction_id, 'ativo', p_order_id, 'venda',
    v_order.client_code, v_order.client_name,
    oi.product_code, oi.product_name, oi.qty, oi.unit_price, oi.total,
    coalesce(p_date, current_date), v_movement_obs, v_uid
  from public.order_items oi
  where oi.order_id = p_order_id;

  update public.orders o set status = 'entregue'
  where o.id = p_order_id and o.user_id = v_uid;

  return jsonb_build_object(
    'order_id', p_order_id,
    'transaction_id', v_transaction_id,
    'items', v_item_count,
    'total', v_order.total
  );
end;
$$;

create or replace function public.pendura_cancel_movement(
  p_movement_id text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_transaction_id text;
  v_client_code text;
  v_type text;
  v_source_order_id text;
  v_group_total numeric;
  v_group_count integer;
  v_debt numeric;
  v_reopened_count integer := 0;
begin
  if v_uid is null or not private.is_active_user() then
    raise exception 'Acesso negado.' using errcode = '42501';
  end if;
  if nullif(btrim(p_reason), '') is null or length(btrim(p_reason)) < 3 then
    raise exception 'Informe um motivo com pelo menos 3 caracteres.' using errcode = '22023';
  end if;

  select m.transaction_id, m.client_code, m.type, m.source_order_id
    into v_transaction_id, v_client_code, v_type, v_source_order_id
  from public.movements m
  where m.id = p_movement_id and m.user_id = v_uid
  for update;
  if not found then
    raise exception 'Movimentação não encontrada.' using errcode = 'P0002';
  end if;

  perform 1
  from public.movements m
  where m.user_id = v_uid and m.transaction_id = v_transaction_id
  for update;

  if exists (
    select 1 from public.movements m
    where m.user_id = v_uid
      and m.transaction_id = v_transaction_id
      and m.status = 'cancelado'
  ) then
    raise exception 'Esta movimentação já foi cancelada.' using errcode = '23514';
  end if;

  if exists (
    select 1 from public.movements m
    where m.user_id = v_uid
      and m.transaction_id = v_transaction_id
      and m.type <> v_type
  ) then
    raise exception 'Transação inconsistente. Contate o suporte.' using errcode = '23514';
  end if;

  perform 1 from public.clients c
  where c.code = v_client_code and c.user_id = v_uid
  for update;
  if not found then
    raise exception 'Cliente da movimentação não encontrado.' using errcode = 'P0002';
  end if;

  select count(*), coalesce(sum(m.total), 0)
    into v_group_count, v_group_total
  from public.movements m
  where m.user_id = v_uid
    and m.transaction_id = v_transaction_id
    and m.status = 'ativo';

  select coalesce(sum(
    case m.type when 'venda' then m.total when 'pagamento' then -m.total else 0 end
  ), 0)
  into v_debt
  from public.movements m
  where m.user_id = v_uid
    and m.client_code = v_client_code
    and m.status = 'ativo';

  if v_type = 'venda' and v_debt - v_group_total < -0.009 then
    raise exception
      'Esta venda já possui pagamento vinculado ao saldo. Cancele primeiro os pagamentos mais recentes.'
      using errcode = '23514';
  end if;

  update public.movements m
  set status = 'cancelado',
      canceled_at = clock_timestamp(),
      canceled_reason = btrim(p_reason),
      canceled_by = v_uid
  where m.user_id = v_uid
    and m.transaction_id = v_transaction_id
    and m.status = 'ativo';

  if v_source_order_id is not null then
    update public.orders o
    set status = 'pronto'
    where o.id = v_source_order_id
      and o.user_id = v_uid
      and o.status = 'entregue';
    get diagnostics v_reopened_count = row_count;
  end if;

  return jsonb_build_object(
    'transaction_id', v_transaction_id,
    'type', v_type,
    'items', v_group_count,
    'total', v_group_total,
    'reopened_order', v_reopened_count > 0
  );
end;
$$;

revoke all on function public.pendura_add_sale(text, text, date, text, jsonb)
  from public, anon;
revoke all on function public.pendura_cancel_movement(text, text)
  from public, anon;
grant execute on function public.pendura_add_sale(text, text, date, text, jsonb)
  to authenticated;
grant execute on function public.pendura_cancel_movement(text, text)
  to authenticated;

-- A exclusão física deixa de estar disponível para o aplicativo.
drop policy if exists movements_delete_own on public.movements;

commit;
