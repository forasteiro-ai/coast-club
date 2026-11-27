-- ============================================================
--  UTILITÁRIO · Coast Club · limpar agendamentos de teste
--  Apaga SÓ agendamentos com nome de teste que eu criei durante
--  a validação do sistema. Cliente real não entra aqui.
--  Cole no SQL Editor e clique em Run.
-- ============================================================

-- ── passo 1: veja o que existe hoje na agenda ──────────────
-- Rode só esta parte primeiro para você conferir com os olhos.
select code, date, time, client_name, service_name, total, status
from public.bookings
where status <> 'cancelado'
order by date, time;

-- ── passo 2: apague apenas os nomes de teste ───────────────
-- A lista cobre todos os nomes que usei nos meus testes.
-- Se um dia você mesmo criar uma reserva chamada "Teste", ela
-- também sai — por isso o passo 1 vem antes.
delete from public.bookings
where client_name ilike any (array[
  'teste%',
  'verifica%',
  'checagem%',
  'limpeza%',
  'aband%',
  'outra pessoa'
])
or client_name in ('A', 'Corte Teste', 'Barba Teste');

-- ── passo 3: confirme ──────────────────────────────────────
-- Os dois selects devem voltar VAZIOS.
select date, time from public.busy_slots order by date, time;

select count(*) as agendamentos_ativos
from public.bookings
where status <> 'cancelado';
