-- ============================================================
--  Coast Club & Barber Shop · Backend Supabase · VERSÃO FINAL
--  Arquivo ÚNICO. Contém tudo: tabelas, RLS, regras de negócio,
--  pagamento real (InfinitePay) e todas as correções.
--
--  Cole inteiro no SQL Editor do Supabase e rode.
--  É idempotente: pode rodar quantas vezes quiser.
--  NÃO apaga agendamentos existentes.
--
--  Consolida (e substitui) as migrações antigas de sinal,
--  limite por WhatsApp e pagamento real.
-- ============================================================

create extension if not exists pgcrypto;

-- ============================================================
--  FUSO HORÁRIO — leia antes de mexer
--  O Postgres do Supabase roda em UTC. Comparar (date + time)
--  com now() sem fuso faz um horário de Brasília que ainda não
--  chegou ser recusado como "já passou" (UTC está 3h à frente).
--  Por isso as comparações abaixo usam explicitamente o fuso da
--  loja via store_tz(). NÃO volte a comparar com now() direto.
-- ============================================================
create or replace function public.store_tz()
returns text language sql immutable as $$ select 'America/Sao_Paulo'::text $$;

-- ---------- donos (quem enxerga os agendamentos) ----------
create table if not exists public.owners (
  email text primary key,
  created_at timestamptz not null default now()
);

-- ---------- configurações (linha única) ----------
create table if not exists public.settings (
  id          int primary key default 1 check (id = 1),
  shop        text not null default 'Coast Club & Barber Shop',
  handle      text not null default '@coastclub_barbershop',
  owner_name  text not null default 'Igor',
  owner_whats text not null default '(11) 99560-6334',
  open_hour   int  not null default 9,
  close_hour  int  not null default 19,
  lunch_hour  int  not null default 12,
  pin         text not null default '1234',
  updated_at  timestamptz not null default now()
);

-- para bancos que já existiam antes da coluna owner_name
alter table public.settings add column if not exists owner_name text not null default 'Igor';

-- percentual do sinal cobrado para segurar o horário (0 = não cobra sinal)
alter table public.settings add column if not exists deposit_pct int not null default 100;
alter table public.settings drop constraint if exists settings_deposit_pct_chk;
alter table public.settings add constraint settings_deposit_pct_chk
  check (deposit_pct between 0 and 100);

-- passo da grade de horários, em minutos (30 em 30)
alter table public.settings add column if not exists slot_minutes int not null default 30;
alter table public.settings drop constraint if exists settings_slot_minutes_chk;
alter table public.settings add constraint settings_slot_minutes_chk
  check (slot_minutes between 15 and 60);

-- quantas reservas ATIVAS o mesmo WhatsApp pode ter (0 = sem limite)
alter table public.settings add column if not exists max_active_per_wa int not null default 1;
alter table public.settings drop constraint if exists settings_max_wa_chk;
alter table public.settings add constraint settings_max_wa_chk
  check (max_active_per_wa between 0 and 10);

-- quantos minutos um horario fica reservado esperando o pagamento
alter table public.settings add column if not exists hold_minutes int not null default 15;
alter table public.settings drop constraint if exists settings_hold_chk;
alter table public.settings add constraint settings_hold_chk
  check (hold_minutes between 5 and 120);

-- ---------- serviços ----------
create table if not exists public.services (
  id     text primary key,
  name   text not null,
  price  numeric(10,2) not null default 0 check (price >= 0),
  ico    text not null default '✂️',
  sort   int  not null default 0,
  active boolean not null default true
);

-- cada serviço tem sua duração. Sobrancelha é 15 min; o resto 30.
alter table public.services add column if not exists duration_min int not null default 30;
alter table public.services drop constraint if exists services_duration_chk;
alter table public.services add constraint services_duration_chk
  check (duration_min between 5 and 240);
update public.services set duration_min = 15 where id = 'sobrancelha';

-- ---------- cupons ----------
create table if not exists public.coupons (
  code   text primary key,
  pct    int not null check (pct between 0 and 100),
  active boolean not null default true
);

-- ---------- agendamentos ----------
create sequence if not exists public.booking_seq;

create table if not exists public.bookings (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique
               default ('CC' || to_char(now(), 'YYMM') || '-' || lpad(nextval('public.booking_seq')::text, 3, '0')),
  date         date not null,
  time         time not null,
  service_id   text not null references public.services(id),
  service_name text not null,
  base         numeric(10,2) not null,
  coupon       text,
  coupon_pct   int not null default 0,
  total        numeric(10,2) not null,
  client_name  text not null,
  client_wa    text not null,
  client_email text,
  pay_method   text not null check (pay_method in ('pix','card')),
  pay_last4    text,
  status       text not null default 'pendente' check (status in ('pendente','pago','cancelado')),
  deposit_pct  int not null default 0,
  deposit      numeric(10,2) not null default 0,
  created_at   timestamptz not null default now()
);

-- para bancos que já existiam antes do sinal
alter table public.bookings add column if not exists deposit_pct int     not null default 0;
alter table public.bookings add column if not exists deposit     numeric(10,2) not null default 0;

-- gateway de pagamento: o que o provedor precisa para conciliar
alter table public.bookings add column if not exists pay_ref    text;
alter table public.bookings add column if not exists pay_url    text;
alter table public.bookings add column if not exists paid_at    timestamptz;

-- duração da reserva e lista dos serviços escolhidos
-- (uma reserva pode ter vários: corte + barba + nevou)
alter table public.bookings add column if not exists duration_min  int    not null default 60;
alter table public.bookings add column if not exists service_ids   text[] not null default '{}';
alter table public.bookings add column if not exists service_names text;

update public.bookings set duration_min = 60 where duration_min is null or duration_min = 0;
update public.bookings set service_ids = array[service_id]
 where (service_ids is null or cardinality(service_ids) = 0) and service_id is not null;
update public.bookings set service_names = service_name
 where service_names is null and service_name is not null;

-- o coração da coisa: um horário só pode ter UM agendamento ativo.
-- Se dois clientes tentarem ao mesmo tempo, o banco recusa o segundo.
create unique index if not exists bookings_slot_uniq
  on public.bookings (date, time) where status <> 'cancelado';

create index if not exists bookings_date_idx on public.bookings (date);

-- ============================================================
--  Quem é dono?
-- ============================================================
create or replace function public.is_owner()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.owners
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

-- ============================================================
--  Um horário está realmente preso?
--  Reserva pendente com o prazo de pagamento vencido NÃO segura o horário.
--  Sem isso, quem abre o checkout e desiste trava o horário para sempre.
-- ============================================================
create or replace function public.booking_holds_slot(
  p_status       text,
  p_created_at   timestamptz,
  p_hold_minutes int,
  p_now          timestamptz default now()
) returns boolean
language sql stable
as $$
  -- recebe "agora" por parâmetro para poder ser testável e determinística
  select case
    when p_status = 'cancelado' then false
    when p_status = 'pendente'
         and p_created_at < p_now - make_interval(mins => coalesce(p_hold_minutes, 15)) then false
    else true
  end;
$$;

-- ============================================================
--  Horários ocupados (público) — só data e hora, sem dados de cliente
-- ============================================================
create or replace view public.busy_slots as
  select b.date, b.time, greatest(coalesce(b.duration_min, 60), 1) as duration_min
  from public.bookings b
  join public.settings s on s.id = 1
  where public.booking_holds_slot(b.status, b.created_at, s.hold_minutes, now())
    and b.date >= (now() at time zone public.store_tz())::date;

-- ============================================================
--  RLS
-- ============================================================
alter table public.owners   enable row level security;
alter table public.settings enable row level security;
alter table public.services enable row level security;
alter table public.coupons  enable row level security;
alter table public.bookings enable row level security;

-- owners: cada um só vê o próprio registro
drop policy if exists owners_self on public.owners;
create policy owners_self on public.owners
  for select to authenticated using (lower(email) = lower(auth.jwt() ->> 'email'));

-- settings: a tabela (que tem o PIN) só o dono lê. O cliente usa settings_public.
drop policy if exists settings_read  on public.settings;
drop policy if exists settings_write on public.settings;
create policy settings_read  on public.settings for select to authenticated
  using (public.is_owner());
create policy settings_write on public.settings for update to authenticated
  using (public.is_owner()) with check (public.is_owner());

-- services: leitura pública, escrita do dono
drop policy if exists services_read  on public.services;
drop policy if exists services_write on public.services;
create policy services_read  on public.services for select to anon, authenticated using (active);
create policy services_write on public.services for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

-- cupons: só o dono lê a tabela; o cliente usa via quote()/book_slot()
drop policy if exists coupons_owner on public.coupons;
create policy coupons_owner on public.coupons for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

-- bookings: ninguém lê direto pelo cliente. Dono lê e altera tudo.
drop policy if exists bookings_owner on public.bookings;
create policy bookings_owner on public.bookings for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

-- a view é pública
grant select on public.busy_slots to anon, authenticated;

-- Configuração pública: tudo o que o app do cliente precisa para montar a grade,
-- SEM o PIN (que é só fallback local e não deve trafegar para o cliente).
create or replace view public.settings_public as
  select id, shop, handle, owner_name, owner_whats, open_hour, close_hour, lunch_hour,
         deposit_pct, max_active_per_wa, hold_minutes, slot_minutes
  from public.settings;

grant select on public.settings_public to anon, authenticated;

-- Grants de tabela (o Supabase já cria isso por padrão para anon/authenticated;
-- declaramos aqui para o schema ser autossuficiente). Quem filtra de verdade é o RLS.
grant usage on schema public to anon, authenticated;
grant select on public.services to anon, authenticated;
grant select, insert, update, delete
  on public.owners, public.settings, public.services, public.coupons, public.bookings
  to authenticated;

-- ============================================================
--  RPC: cotação (preço e cupom calculados no servidor)
-- (quote de 1 serviço: substituída na seção final "HORÁRIOS CURTOS")

-- ============================================================
--  RPC: reservar (atômico, valida tudo no servidor)
-- (book_slot de 1 serviço: substituída na seção final "HORÁRIOS CURTOS")

-- ============================================================
--  RPC: consultar um agendamento pelo id (o cliente guarda o id)
-- ============================================================
create or replace function public.get_booking(p_id uuid)
returns jsonb
language sql security definer set search_path = public
as $$
  select to_jsonb(b) from bookings b where b.id = p_id;
$$;

-- ============================================================
--  RPC: cliente cancela o próprio horário (id + whatsapp)
-- ============================================================
create or replace function public.cancel_booking(p_id uuid, p_wa text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_row bookings;
  v_d   text := regexp_replace(coalesce(p_wa, ''), '\D', '', 'g');
  v_bd  text;
begin
  select * into v_row from bookings where id = p_id;
  if v_row.id is null then
    return jsonb_build_object('ok', false, 'error', 'nao_encontrado');
  end if;
  v_bd := regexp_replace(v_row.client_wa, '\D', '', 'g');
  if right(v_bd, 10) <> right(v_d, 10) then
    return jsonb_build_object('ok', false, 'error', 'whatsapp_nao_confere');
  end if;
  if v_row.status = 'cancelado' then
    return jsonb_build_object('ok', true, 'booking', to_jsonb(v_row));
  end if;
  if (v_row.date + v_row.time) at time zone public.store_tz() <= now() then
    return jsonb_build_object('ok', false, 'error', 'ja_passou');
  end if;

  update bookings set status = 'cancelado' where id = p_id returning * into v_row;
  return jsonb_build_object('ok', true, 'booking', to_jsonb(v_row));
end $$;

-- ============================================================
--  Permissões das funções
-- ============================================================
grant execute on function public.get_booking(uuid)                                     to anon, authenticated;
grant execute on function public.cancel_booking(uuid, text)                            to anon, authenticated;
grant execute on function public.is_owner()                                            to authenticated;

-- ============================================================
--  Dados iniciais
-- ============================================================
insert into public.settings (id) values (1) on conflict (id) do nothing;
update public.settings set owner_name = 'Igor', owner_whats = '(11) 99560-6334'
  where id = 1 and (owner_whats is null or owner_whats = '');

insert into public.services (id, name, price, ico, sort) values
  ('corte-adulto',   'Corte Adulto',        35, '✂️', 1),
  ('corte-infantil', 'Corte Infantil',      35, '🧒', 2),
  ('barba',          'Barba',               20, '🪒', 3),
  ('sobrancelha',    'Sobrancelha',         15, '👁️', 4),
  ('limpeza',        'Limpeza de Pele',     30, '🧖', 5),
  ('luzes',          'Luzes',               60, '💡', 6),
  ('nevou',          'Platinado / Nevou',   75, '🤍', 7),
  ('pezinho',        'Pézinho',             15, '🦶', 8),
  ('risquinho',      'Risquinho / Desenho', 15, '📐', 9)
on conflict (id) do nothing;

-- preços oficiais da tabela do Igor (sobrescreve a rodada anterior)
update public.services set price = 40, name = 'Corte Adulto'        where id = 'corte-adulto';
update public.services set price = 40, name = 'Corte Infantil'      where id = 'corte-infantil';
update public.services set price = 25, name = 'Barba'               where id = 'barba';
update public.services set price = 18, name = 'Sobrancelha'         where id = 'sobrancelha';
update public.services set price = 35, name = 'Limpeza de Pele'     where id = 'limpeza';
update public.services set price = 65, name = 'Luzes'               where id = 'luzes';
update public.services set price = 80, name = 'Platinado / Nevou'   where id = 'nevou';
update public.services set price = 15, name = 'Pézinho'             where id = 'pezinho';
update public.services set price = 20, name = 'Risquinho / Desenho' where id = 'risquinho';

-- o Pacote Mensal não está na tabela do Igor: sai de linha
update public.services set active = false where id = 'pacote';

insert into public.coupons (code, pct) values ('COAST10', 10)
on conflict (code) do nothing;

-- ============================================================
--  IMPORTANTE: troque o e-mail abaixo pelo seu (o que você vai
--  usar para logar no painel) e rode esta linha.
-- ============================================================
-- insert into public.owners (email) values ('seu-email@gmail.com')
--   on conflict (email) do nothing;

-- Enquanto você não cadastrar um dono, NINGUÉM lê os agendamentos
-- pela API — só a service_role key (que fica fora do app).

-- ============================================================
--  PAGAMENTO REAL (InfinitePay)
--  Nenhuma reserva nasce 'pago'. Quem confirma é o pagamento,
--  pela confirm_payment(), chamada só pelo servidor (service_role).
--  Incluído nesta versão final em 26/11/2026.
-- ============================================================

-- (book_slot de 1 serviço: substituída na seção final "HORÁRIOS CURTOS")

-- ── 2. valor a cobrar de uma reserva ───────────────────────
-- A Edge Function pergunta aqui quanto cobrar. Nunca confia no
-- valor que o navegador manda.
create or replace function public.amount_due(p_id uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'ok',      true,
    'amount',  b.deposit,
    'total',   b.total,
    'status',  b.status,
    'code',    b.code,
    'service', b.service_name,
    'name',    b.client_name
  )
  from public.bookings b
  where b.id = p_id;
$$;

-- ── 3. grava o link de pagamento na reserva ────────────────
create or replace function public.set_payment_link(
  p_id  uuid,
  p_ref text,
  p_url text
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_row bookings;
begin
  update public.bookings
     set pay_ref = p_ref,
         pay_url = p_url
   where id = p_id
     and status = 'pendente'
  returning * into v_row;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'nao_encontrado_ou_ja_pago');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- ── 4. CONFIRMA o pagamento (só o servidor chama) ──────────
-- É a única função que promove reserva para 'pago'.
-- O webhook da InfinitePay chega na Edge Function, que chama isto
-- com a chave de serviço. O anon não tem permissão.
create or replace function public.confirm_payment(
  p_id     uuid,
  p_ref    text default null,
  p_method text default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_row bookings;
begin
  if p_method is not null and p_method not in ('pix', 'card') then
    return jsonb_build_object('ok', false, 'error', 'metodo_invalido');
  end if;

  begin
    update public.bookings
       set status     = 'pago',
           paid_at    = now(),
           pay_ref    = coalesce(p_ref, pay_ref),
           pay_method = coalesce(p_method, pay_method)
     where id = p_id
       and status <> 'pago'
    returning * into v_row;
  exception
    when unique_violation then
      -- o prazo do link venceu e outro cliente pegou o horário
      return jsonb_build_object('ok', false, 'error', 'horario_ocupado');
  end;

  if not found then
    -- já estava pago (webhook repetido) ou não existe: responder ok
    -- para o provedor parar de reenviar
    return jsonb_build_object('ok', true, 'ja_pago', true);
  end if;

  return jsonb_build_object('ok', true, 'code', v_row.code, 'status', v_row.status);
end;
$$;

-- ── 5. libera o horário de reserva pendente vencida ────────
-- Chamável pelo webhook e por um job. Só toca em pendente velho.
create or replace function public.release_expired()
returns int
language plpgsql security definer set search_path = public
as $$
declare v_set settings; v_n int;
begin
  select * into v_set from public.settings where id = 1;
  with mortas as (
    update public.bookings
       set status = 'cancelado'
     where status = 'pendente'
       and created_at < now() - make_interval(mins => coalesce(v_set.hold_minutes, 15))
    returning 1
  )
  select count(*) into v_n from mortas;
  return v_n;
end;
$$;

-- ── 6. PERMISSÕES ──────────────────────────────────────────
-- O navegador pode criar reserva (pendente) e ver o valor a pagar.
-- NUNCA pode confirmar pagamento nem gravar link.
revoke all on function public.confirm_payment(uuid, text, text) from public, anon, authenticated;
revoke all on function public.set_payment_link(uuid, text, text) from public, anon, authenticated;
revoke all on function public.release_expired() from public, anon, authenticated;

grant execute on function public.confirm_payment(uuid, text, text) to service_role;
grant execute on function public.set_payment_link(uuid, text, text) to service_role;
grant execute on function public.release_expired() to service_role;

grant execute on function public.amount_due(uuid) to anon, authenticated;

-- ================================================================
--  HORÁRIOS CURTOS E VÁRIOS SERVIÇOS POR RESERVA
--  (incorporado em 27/11/2026 — é a ÚNICA definição de book_slot e
--   quote que vale; as versões de 1 serviço foram removidas acima)
-- ================================================================

-- ============================================================
--  Coast Club · horários de 30 min + vários serviços por reserva
--  Migração de 27/11/2026 (revisada: duração POR SERVIÇO)
--
--  REGRAS
--  · A grade de horários é de 30 em 30 minutos (settings.slot_minutes).
--  · Cada serviço tem sua própria duração (services.duration_min):
--      Sobrancelha ............. 15 min
--      todos os outros ......... 30 min
--  · O cliente escolhe VÁRIOS serviços numa reserva só. A reserva
--    ocupa a SOMA das durações:
--      Corte + Barba ........... 60 min  (1 hora)
--      Corte + Barba + Nevou ... 90 min  (1 hora e meia)
--      Só Sobrancelha .......... 15 min
--  · Um horário não pode ser vendido duas vezes. A garantia sai do
--    índice único (date,time) e passa a ser uma EXCLUSION CONSTRAINT
--    por FAIXA DE TEMPO: sem isso, marcar 09:00 com 1h e outro marcar
--    09:30 passaria pelas duas checagens e o Igor teria dois clientes
--    na mesma cadeira.
--
--  IDEMPOTENTE: pode rodar quantas vezes quiser.
-- ============================================================

-- ---------- 1. duração de cada serviço ----------
alter table public.services add column if not exists duration_min int not null default 30;
alter table public.services drop constraint if exists services_duration_chk;
alter table public.services add constraint services_duration_chk
  check (duration_min between 5 and 240);

-- Sobrancelha é o único serviço de 15 minutos (pedido do Igor).
update public.services set duration_min = 15 where id = 'sobrancelha';
update public.services set duration_min = 30
 where id <> 'sobrancelha' and (duration_min is null or duration_min <> 30);

-- ---------- 2. passo da grade ----------
alter table public.settings add column if not exists slot_minutes int not null default 30;
alter table public.settings drop constraint if exists settings_slot_minutes_chk;
alter table public.settings add constraint settings_slot_minutes_chk
  check (slot_minutes between 15 and 60);

-- ---------- 3. duração total da reserva ----------
alter table public.bookings add column if not exists duration_min int not null default 60;
alter table public.bookings add column if not exists service_ids   text[] not null default '{}';
alter table public.bookings add column if not exists service_names text;

-- reservas antigas: cada uma ocupava 1 hora
update public.bookings set duration_min = 60 where duration_min is null or duration_min = 0;

update public.bookings
   set service_ids = array[service_id]
 where (service_ids is null or cardinality(service_ids) = 0)
   and service_id is not null;

update public.bookings
   set service_names = service_name
 where service_names is null and service_name is not null;

-- ---------- 4. faixa de tempo que a reserva ocupa ----------
create or replace function public.slot_span(p_date date, p_time time, p_duration int)
returns tsrange
language sql immutable
as $$
  select tsrange(
    (p_date + p_time)::timestamp,
    (p_date + p_time)::timestamp + make_interval(mins => greatest(coalesce(p_duration, 30), 1)),
    '[)'
  );
$$;

drop index if exists public.bookings_slot_uniq;

-- ---------- 5. troca do índice único por exclusão de faixa ----------
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'bookings_no_overlap'
      and conrelid = 'public.bookings'::regclass
  ) then
    alter table public.bookings
      add constraint bookings_no_overlap
      exclude using gist (public.slot_span(date, time, duration_min) with &&)
      where (status <> 'cancelado');
  end if;
end $$;

create index if not exists bookings_date_idx on public.bookings (date);

-- ---------- 6. cotação de VÁRIOS serviços ----------
create or replace function public.quote_multi(
  p_service_ids text[],
  p_coupon      text default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_ids     text[];
  v_base    numeric(10,2);
  v_dur     int;
  v_n       int;
  v_pct     int := 0;
  v_code    text := nullif(upper(trim(coalesce(p_coupon, ''))), '');
  v_dep_pct int;
  v_total   numeric(10,2);
  v_dep     numeric(10,2);
  v_names   text;
begin
  select array_agg(x order by ord)
    into v_ids
    from (select distinct on (x) x, ord
            from unnest(coalesce(p_service_ids, '{}')) with ordinality as t(x, ord)
           where x is not null and length(trim(x)) > 0
           order by x, ord) sub;

  if v_ids is null or array_length(v_ids, 1) is null then
    return jsonb_build_object('ok', false, 'error', 'nenhum_servico');
  end if;

  select sum(price), sum(duration_min), count(*), string_agg(name, ' + ' order by name)
    into v_base, v_dur, v_n, v_names
    from services
   where id = any(v_ids) and active;

  if v_n is null or v_n <> array_length(v_ids, 1) then
    return jsonb_build_object('ok', false, 'error', 'servico_indisponivel');
  end if;

  if v_code is not null then
    select pct into v_pct from coupons where code = v_code and active;
    if v_pct is null then
      v_pct := 0;
      v_code := null;
    end if;
  end if;

  v_dep_pct := (select deposit_pct from settings where id = 1);
  v_total   := round(v_base * (100 - v_pct) / 100.0, 2);
  v_dep     := round(v_total * coalesce(v_dep_pct, 0) / 100.0, 2);

  return jsonb_build_object(
    'ok',         true,
    'base',       v_base,
    'services',   v_n,
    'names',      v_names,
    'duration',   coalesce(v_dur, 30),
    'coupon',     v_code,
    'coupon_pct', v_pct,
    'off',        round(v_base * v_pct / 100.0, 2),
    'total',      v_total,
    'deposit_pct', coalesce(v_dep_pct, 0),
    'deposit',    v_dep,
    'rest',       round(v_total - v_dep, 2)
  );
end $$;

create or replace function public.quote(p_service_id text, p_coupon text default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  return public.quote_multi(array[p_service_id], p_coupon);
end $$;

-- ---------- 7. book_slot aceitando vários serviços ----------
drop function if exists public.book_slot(text, date, time, text, text, text, text, text, text);

create or replace function public.book_slot(
  p_service_ids text[],
  p_date        date,
  p_time        time,
  p_name        text,
  p_wa          text,
  p_email       text default null,
  p_coupon      text default null,
  p_method      text default 'pix',
  p_last4       text default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_set   settings;
  v_q     jsonb;
  v_row   bookings;
  v_hour  int;
  v_min   int;
  v_step  int;
  v_dur   int;
  v_n     int;
  v_end   time;
  v_names text;
  v_ids   text[];
begin
  if p_name is null or length(trim(p_name)) < 3 then
    return jsonb_build_object('ok', false, 'error', 'nome_invalido');
  end if;
  if p_wa is null or length(regexp_replace(p_wa, '\D', '', 'g')) < 10 then
    return jsonb_build_object('ok', false, 'error', 'whatsapp_invalido');
  end if;
  if p_method is null or p_method not in ('pix', 'card') then
    return jsonb_build_object('ok', false, 'error', 'pagamento_invalido');
  end if;

  select * into v_set from settings where id = 1;
  v_step := coalesce(v_set.slot_minutes, 30);

  v_q := public.quote_multi(p_service_ids, p_coupon);
  if not (v_q ->> 'ok')::boolean then
    return v_q;
  end if;
  v_n   := (v_q ->> 'services')::int;
  v_dur := (v_q ->> 'duration')::int;

  select array_agg(id order by id) into v_ids
    from services where id = any(p_service_ids) and active;
  select string_agg(name, ' + ' order by name) into v_names
    from services where id = any(v_ids);

  if extract(dow from p_date) = 0 then
    return jsonb_build_object('ok', false, 'error', 'domingo_fechado');
  end if;

  v_hour := extract(hour from p_time);
  v_min  := extract(minute from p_time);
  if v_min % v_step <> 0 then
    return jsonb_build_object('ok', false, 'error', 'horario_fora_da_grade', 'slot', v_step);
  end if;

  if v_hour < v_set.open_hour or v_hour >= v_set.close_hour then
    return jsonb_build_object('ok', false, 'error', 'fora_do_horario');
  end if;
  if v_hour = v_set.lunch_hour then
    return jsonb_build_object('ok', false, 'error', 'horario_de_almoco');
  end if;

  v_end := p_time + make_interval(mins => v_dur);
  if p_time < make_time(v_set.lunch_hour, 0, 0)
     and v_end > make_time(v_set.lunch_hour, 0, 0) then
    return jsonb_build_object('ok', false, 'error', 'passa_do_almoco');
  end if;
  if v_end > make_time(v_set.close_hour, 0, 0) then
    return jsonb_build_object('ok', false, 'error', 'passa_do_fechamento');
  end if;

  if (p_date + p_time) at time zone public.store_tz() <= now() then
    return jsonb_build_object('ok', false, 'error', 'horario_passado');
  end if;

  if coalesce(v_set.max_active_per_wa, 0) > 0 then
    perform pg_advisory_xact_lock(hashtext(right(regexp_replace(p_wa, '\D', '', 'g'), 10)));
    if (
      select count(*)
      from public.bookings b
      where b.status <> 'cancelado'
        and right(regexp_replace(b.client_wa, '\D', '', 'g'), 10)
          = right(regexp_replace(p_wa, '\D', '', 'g'), 10)
        and (b.date + b.time) at time zone public.store_tz() > now()
    ) >= v_set.max_active_per_wa then
      return jsonb_build_object('ok', false, 'error', 'limite_reservas', 'max', v_set.max_active_per_wa);
    end if;
  end if;

  begin
    insert into bookings (
      date, time, service_id, service_name, service_ids, service_names,
      duration_min, base, coupon, coupon_pct, total,
      client_name, client_wa, client_email, pay_method, pay_last4, status,
      deposit_pct, deposit
    ) values (
      p_date, p_time,
      v_ids[1], coalesce(v_names, ''),
      v_ids, v_names, v_dur,
      (v_q ->> 'base')::numeric,
      v_q ->> 'coupon', (v_q ->> 'coupon_pct')::int, (v_q ->> 'total')::numeric,
      trim(p_name), trim(p_wa),
      nullif(trim(coalesce(p_email, '')), ''),
      p_method, nullif(trim(coalesce(p_last4, '')), ''),
      'pendente',
      (v_q ->> 'deposit_pct')::int, (v_q ->> 'deposit')::numeric
    )
    returning * into v_row;
  exception
    when exclusion_violation then
      return jsonb_build_object('ok', false, 'error', 'horario_ocupado');
    when unique_violation then
      return jsonb_build_object('ok', false, 'error', 'horario_ocupado');
  end;

  return jsonb_build_object('ok', true, 'booking', to_jsonb(v_row));
end $$;

-- ---------- 8. permissões ----------
grant execute on function public.quote_multi(text[], text) to anon, authenticated;
grant execute on function public.book_slot(text[], date, time, text, text, text, text, text, text) to anon, authenticated;

-- ---------- 9. amount_due usa a lista de serviços e a duração ----------
create or replace function public.amount_due(p_id uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'ok',       true,
    'amount',   b.deposit,
    'total',    b.total,
    'status',   b.status,
    'code',     b.code,
    'service',  coalesce(b.service_names, b.service_name),
    'duration', b.duration_min,
    'name',     b.client_name
  )
  from public.bookings b
  where b.id = p_id;
$$;

-- ---------- 10. busy_slots informa a DURAÇÃO ocupada ----------
create or replace view public.busy_slots as
  select b.date, b.time, greatest(coalesce(b.duration_min, 60), 1) as duration_min
  from public.bookings b
  join public.settings s on s.id = 1
  where public.booking_holds_slot(b.status, b.created_at, s.hold_minutes, now())
    and b.date >= (now() at time zone public.store_tz())::date;

grant select on public.busy_slots to anon, authenticated;

-- ---------- 11. settings_public expõe o passo da grade ----------
create or replace view public.settings_public as
  select id, shop, handle, owner_name, owner_whats, open_hour, close_hour, lunch_hour,
         deposit_pct, max_active_per_wa, hold_minutes, slot_minutes
  from public.settings;

grant select on public.settings_public to anon, authenticated;

