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

-- ---------- 12. conferência ----------
do $$
declare
  v_step int; v_sob int; v_corte int; v_excl int; v_fn int;
begin
  select slot_minutes into v_step from public.settings where id = 1;
  select duration_min into v_sob   from public.services where id = 'sobrancelha';
  select duration_min into v_corte from public.services where id = 'corte-adulto';

  select count(*) into v_fn from pg_proc
   where pronamespace = 'public'::regnamespace and proname in ('quote_multi', 'slot_span');

  select count(*) into v_excl from pg_constraint
   where conname = 'bookings_no_overlap' and conrelid = 'public.bookings'::regclass;

  raise notice 'grade=% min · sobrancelha=% min · corte=% min · funcoes=%/2 · constraint=%',
    v_step, v_sob, v_corte, v_fn, v_excl;

  if v_step <> 30 then raise exception 'slot_minutes deveria ser 30, veio %', v_step; end if;
  if v_sob is distinct from 15 then raise exception 'sobrancelha deveria ter 15 min, veio %', v_sob; end if;
  if v_corte is distinct from 30 then raise exception 'corte deveria ter 30 min, veio %', v_corte; end if;
  if v_fn <> 2 or v_excl <> 1 then raise exception 'migração incompleta: funcoes=%, constraint=%', v_fn, v_excl; end if;
end $$;
