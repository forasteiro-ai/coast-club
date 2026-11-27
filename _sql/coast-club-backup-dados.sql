-- ============================================================
--  Coast Club · BACKUP COMPLETO dos dados
--
--  Cole no SQL Editor do Supabase e clique em Run.
--  Ele devolve UMA linha com todo o conteúdo do banco em JSON.
--  Copie o resultado para um arquivo .json e guarde no Drive.
--
--  Rode isso antes de qualquer mudança grande, e uma vez por mês.
--  É um SELECT: não altera nada no banco.
-- ============================================================

select jsonb_pretty(
  jsonb_build_object(
    'gerado_em',      now(),
    'projeto',        'coast-club',

    -- configuração da loja (inclui o PIN; NÃO compartilhe este arquivo)
    'settings',       (select to_jsonb(s) from public.settings s where s.id = 1),

    -- tabela de serviços com preço e duração
    'services',       (select jsonb_agg(to_jsonb(x) order by x.id) from public.services x),

    'coupons',        (select jsonb_agg(to_jsonb(x) order by x.code) from public.coupons x),
    'owners',         (select jsonb_agg(to_jsonb(x) order by x.email) from public.owners x),

    -- TODOS os agendamentos: é o dado que não pode ser perdido
    'bookings',       (select jsonb_agg(to_jsonb(b) order by b.date, b.time)
                         from public.bookings b),

    -- contagem, para conferir depois se o restore ficou completo
    'conferencia',    jsonb_build_object(
                        'agendamentos', (select count(*) from public.bookings),
                        'pagos',        (select count(*) from public.bookings where status = 'pago'),
                        'servicos',     (select count(*) from public.services),
                        'faturamento',  (select coalesce(sum(total), 0) from public.bookings where status = 'pago')
                      )
  )
) as backup;
