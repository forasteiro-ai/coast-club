# Organizar o Supabase — guia passo a passo

**26/11/2026.** Resolve a dúvida: quais SQLs manter, como salvar, como ter certeza.

---

## Primeiro: você não fez nada errado

O botão **Run** (Ctrl+Enter) **executa** o SQL. Não salva o arquivo. São duas coisas diferentes:

| Ação | O que faz | Atalho |
|---|---|---|
| **Run** | Executa o SQL no banco. O banco muda. | Ctrl + Enter |
| **Save** | Salva o texto no seu histórico de queries. O banco não muda. | Ctrl + S |

Você apertou Run em tudo — então **o banco está correto**. O que falta é só organizar o texto na tela, que é cosmético. Nada do app depende disso.

Por isso o Ctrl+W avisa: existe texto no editor que ainda não foi salvo como arquivo. Se você fechar, perde o *texto*, não a alteração no banco.

---

## O estado real do seu banco (verificado agora)

| Item | Valor | Status |
|---|---|---|
| Cobrança na reserva | 100% (valor integral) | ✅ |
| Prazo para pagar | 15 minutos | ✅ |
| Limite por WhatsApp | 1 reserva ativa | ✅ |
| WhatsApp do dono | (11) 99560-6334 | ✅ |
| Horário | 9h às 19h, almoço 12h | ✅ |
| Corta de R$ 35 | cobra R$ 35, resta R$ 0 | ✅ |
| Limite por número | 2ª reserva do mesmo número é recusada | ✅ |

**Tudo está aplicado e funcionando.** O que segue é organização.

---

## Quais SQLs manter

Você tem 4 queries na aba PRIVATE. O veredito:

| Query na sua lista | Manter? | Por quê |
|---|---|---|
| **Migração do valor do sinal** | ❌ apagar | Já rodou. E foi substituída pelo pagamento integral. |
| **MIGRAÇÃO: limite de reservas por WhatsApp** | ❌ apagar | Já rodou. O conteúdo está dentro do schema completo. |
| **SQL limpeza** | ❌ apagar | Já rodou. Serve só para uma vez. |
| **Untitled query** | ❌ apagar | Vazio ou duplicado. |

**No lugar de todos eles, fica UM arquivo só:** `coast-club-SCHEMA-COMPLETO.sql`

Ele contém **tudo**: tabelas, funções, RLS, o sinal, o pagamento integral, o prazo de 15 minutos, o limite por WhatsApp, o fuso horário corrigido, e todas as views. É idempotente — pode rodar quantas vezes quiser, e ele nunca apaga agendamentos existentes.

Esse arquivo é a sua fonte de verdade. Se um dia o Supabase for recriado (na conta do Igor, por exemplo), você cola **este único arquivo** e o banco nasce completo.

---

## Passo a passo para organizar

### 1. Salvar o arquivo definitivo

1. No SQL Editor, clique no **+** para abrir uma query nova
2. Apague o que tiver e cole o conteúdo de `coast-club-SCHEMA-COMPLETO.sql`
3. Clique em **Save** (Ctrl + S) — o botão fica no canto superior direito, ao lado de Run
4. Dê o nome: **`SCHEMA COMPLETO (fonte de verdade)`**
5. Clique em Save de novo para confirmar

### 2. Apagar as queries antigas

Na barra lateral esquerda, seção **PRIVATE**:

1. Passe o mouse sobre a query
2. Aparece um ícone de **três pontinhos** (⋯) à direita
3. Clique nele → **Delete** (ou "Excluir")
4. Confirme

Repita para as 4 antigas. **Atenção:** não apague a que você acabou de salvar.

> Se o menu de três pontinhos não aparecer, clique com o botão direito sobre o nome da query — o menu aparece igual.

### 3. Deixar uma query de limpeza, separada

Faça o mesmo com `coast-club-limpar-tudo.sql`, salvando com o nome **`UTILITÁRIO — limpar testes`**. Ela não é parte do sistema; serve só para remover agendamentos de teste que eu criei. Um dia ela vai deixar de ser útil e você pode apagar.

---

## Como ter certeza de que está salvo

Três provas diferentes, da mais fraca à mais forte:

### Prova 1 — o marcador de "não salvo" desaparece

No topo do editor, ao lado do nome da query, existe um texto **"Unsaved edits"** (edições não salvas). Depois de clicar em Save, ele **desaparece**. Se continua lá, não salvou.

### Prova 2 — o nome da query está na barra lateral

A query aparece em **PRIVATE** com o nome que você deu. Se aparece como "Untitled query", o nome não foi salvo.

### Prova 3 — feche e reabra

Clique em outra query, depois volte na sua. O conteúdo deve estar lá. Essa é a prova definitiva: se sobreviveu a sair e voltar, está no servidor.

### Prova 4 — o banco

O que importa de verdade. Rode num editor qualquer:

```sql
select deposit_pct, max_active_per_wa, hold_minutes,
       owner_whats, open_hour, close_hour
from public.settings_public;
```

Deve devolver exatamente:

| deposit_pct | max_active_per_wa | hold_minutes | owner_whats | open_hour | close_hour |
|---|---|---|---|---|---|
| 100 | 1 | 15 | (11) 99560-6334 | 9 | 19 |

**Guardei esse número.** Depois você pode rodar de novo e comparar.

---

## Como saber se o SQL rodou com sucesso

Quando você clica em Run, o Supabase mostra o resultado embaixo. Os significados:

| O que aparece | Significa |
|---|---|
| **Success. No rows returned** | ✅ Rodou. O comando não devolve dados (ex.: `delete`, `update`, `create`). É o esperado. |
| Uma tabela com linhas | ✅ Rodou e devolveu dados (ex.: um `select`). |
| **Error** com mensagem vermelha | ❌ Não rodou. A mensagem diz o motivo. |
| Nada acontece | ⚠️ Provavelmente o editor está vazio ou só tem comentários. |

O seu print mostra **"1 row"** com `deposit_pct = 100` e `hold_minutes = 15`. Isso é a prova de que a migração rodou.

---

## O que NÃO fazer

- **Não rode `DELETE` em `bookings` sem o filtro de nome** — apagaria agendamentos reais de clientes.
- **Não apague a tabela `settings`** — o app depende dela para funcionar.
- **Não use "Fix with AI"** nos avisos do Security Advisor — ele reescreve as funções e é exatamente como se reintroduz o bug de fuso.
- **Não cole a chave `sb_secret_`** em nenhum lugar do chat.

---

## Resumo em uma linha

**O banco está certo.** Salve o arquivo `SCHEMA COMPLETO` como fonte de verdade, apague os 4 antigos, e você nunca mais precisa lembrar qual migração rodou.
