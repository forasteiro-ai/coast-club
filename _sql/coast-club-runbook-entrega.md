# Runbook · entregar o Coast Club ao Igor

**O que é isto:** a receita para recriar o sistema do zero numa conta nova. Não é explicação — é para seguir com o computador na frente, marcando cada passo. Serve para o dia em que o Supabase passar para a conta do Igor.

Tempo estimado: **40 a 60 minutos**. Faça com calma, na ordem.

---

## Antes de começar: o que vai para onde

| Peça | Onde vive hoje | Vai para |
|---|---|---|
| Banco de dados | projeto Supabase `fjxrkfliobdzvrwqnmme` (sua conta) | projeto novo na conta do Igor |
| Site (arquivos) | GitHub `forasteiro-ai/coast-club` | pode ficar no seu GitHub, apontando para o banco novo |
| Domínio | Registro.br, no nome do Igor | não muda |
| Conta que recebe | InfinitePay do Igor | não muda |
| Cobrança de função | Edge Functions (Supabase) | precisam ser recriadas no projeto novo |

> **A pasta do site vai inteira, não só o `index.html`.** São `index.html`, `manifest.json`, os 4 ícones e as 5 fotos (`fachada`, `ambiente`, `cadeira`, `espera`, `logo`). Já quebrou uma vez: as fotos ficaram fora e deram 404 no ar.

**Decisão que você precisa tomar antes:** o GitHub pode continuar sendo seu. O domínio aponta para ele, e ele aponta para o banco do Igor. Se preferir passar o GitHub também, o Igor precisa de conta lá.

---

## Passo 1 · Criar o projeto Supabase do Igor

1. Ele cria conta em `supabase.com` (pode entrar com GitHub ou e-mail)
2. **New project**
   - Nome: `coast-club`
   - Senha do banco: **gere uma forte e guarde no gerenciador de senhas dele**. Essa senha é dele, não sua.
   - Região: **South America (São Paulo)** — mais perto, mais rápido
3. Aguarde ~2 minutos até o projeto ficar verde

**Anote aqui os dois valores:**

```
Project URL: https://__________________.supabase.co
Project ref: __________________
```

O `ref` são as letras antes de `.supabase.co`.

---

## Passo 2 · Aplicar o banco

1. No projeto novo: **SQL Editor** (menu da esquerda)
2. **New query**
3. Cole o arquivo inteiro `coast-club-SCHEMA-COMPLETO.sql` (823 linhas — já traz horários de 30 min e multisserviço)
4. **Run** (Ctrl+Enter)
5. No fim deve aparecer algo como `Success. No rows returned` e, na última conferência, `grava_pendente = true`

> É idempotente: se der erro no meio, corrija e rode de novo inteiro. Rodar duas vezes não quebra nada nem apaga agendamento.

**Confira que deu certo** — cole isto e rode:

```sql
select deposit_pct, max_active_per_wa, hold_minutes from public.settings where id = 1;
select proname from pg_proc where pronamespace='public'::regnamespace
  and proname in ('amount_due','set_payment_link','confirm_payment','release_expired')
  order by proname;
```

Esperado: a primeira linha com `100`, `1`, `15`; a segunda com 4 nomes.

**Confira também as regras de horário** (se faltar alguma, o banco nasceu sem elas):

```sql
select slot_minutes from public.settings where id = 1;
select id, duration_min, price from public.services order by id;
select conname from pg_constraint where conname = 'bookings_no_overlap';
```

Esperado: `30` · sobrancelha com `15`, os outros com `30` · a constraint `bookings_no_overlap` presente.

---

## Passo 3 · Criar o usuário do dono

1. **Authentication → Users → Add user → Create new user**
2. E-mail: o do Igor (`igorgustavodelima@hotmail.com` ou o que ele usar)
3. Senha: **definida pelo Igor**, que ele guarda
4. Marque **Auto Confirm User** (senão ele não consegue entrar)
5. **Create user**

Depois, registre-o como dono no banco — no SQL Editor:

```sql
insert into public.owners (email) values ('igorgustavodelima@hotmail.com')
on conflict (email) do nothing;
select * from public.owners;
```

> O reconhecimento do dono é pelo **e-mail do login**, não pelo id. Se ele recriar o usuário com o mesmo e-mail, continua funcionando.

---

## Passo 4 · Fechar o cadastro público

Isto evita que qualquer pessoa crie conta no projeto.

1. **Authentication → Sign In / Providers**
2. `Enable email provider` → **ligado** (senão o login do dono para de funcionar)
3. `Allow new users to sign up` → **desligado**
4. **Save** ← não esqueça, o botão verde não salva sozinho

**Teste por fora** (troque `SUA_CHAVE` pela chave pública do projeto novo, em Settings → API Keys):

```bash
K=SUA_CHAVE
B=https://SEU_REF.supabase.co
# login vivo: deve dar 400 (não 422)
curl -s -X POST "$B/auth/v1/token?grant_type=password" \
  -H "apikey: $K" -H "Content-Type: application/json" \
  -d '{"email":"teste@teste.com","password":"errada123"}'
# cadastro fechado: deve dar 422
curl -s -X POST "$B/auth/v1/signup" \
  -H "apikey: $K" -H "Content-Type: application/json" \
  -d '{"email":"x@y.com","password":"SenhaForte123"}'
```

---

## Passo 5 · Publicar as 3 funções

**Nunca** use `import ... from 'jsr:@supabase/supabase-js@2'` — derruba a função com `BOOT_ERROR`. As três já estão escritas sem dependência; só cole.

Os arquivos estão na pasta **3-Funcoes-de-pagamento**: `pay-create.ts`, `pay-check.ts` e `pay-webhook.ts`. Cole o conteúdo de cada um como `index.ts` da função de mesmo nome.

Para cada uma: `pay-create`, `pay-webhook`, `pay-check`

1. **Edge Functions → Deploy a new function → Via Editor**
2. Nome igual ao do arquivo
3. Apague o template e cole o `index.ts` correspondente
4. **Deploy function** (~15s)
5. Abra a função → **Settings** → **desligue** `Enforce JWT verification`
6. Use o botão **Test** para confirmar que responde (não pode vir o template antigo)

> **As TRÊS precisam de `Enforce JWT` desligado**, inclusive a `pay-check`. Se ela ficar exigindo JWT, o pagamento abre mas nunca confirma.

---

## Passo 6 · Os segredos

**Edge Functions → Secrets** (não é dentro de cada função). Crie os 5:

| Nome | Valor |
|---|---|
| `INFINITEPAY_HANDLE` | `igor-gustavo-de-lima-` |
| `PUBLIC_FN_BASE` | `https://SEU_REF.supabase.co/functions/v1` |
| `SITE_URL` | `https://coastclubbarbershop.com.br` |
| `HOLD_MINUTES` | `15` |
| `VERIFY_ON_WEBHOOK` | `0` (vira `1` só se o Igor configurar o webhook) |

`SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` o Supabase injeta sozinho — **não crie**.

> A API Key da InfinitePay é **opcional**: a conta é identificada pela handle. Só crie `INFINITEPAY_API_KEY` se for usar o webhook com verificação.

---

## Passo 7 · Apontar o site para o banco novo

O app guarda a conexão em duas camadas: o padrão no código (`DEFAULTS_CFG`) e o que o navegador salvou (`localStorage`). **O `localStorage` vence** — então só trocar o código não basta numa máquina que já usou o app.

**No arquivo** `index.html` (da pasta **1-Site-para-publicar**), procure `DEFAULTS_CFG` e troque:

```js
const DEFAULTS_CFG = {
  url:'https://SEU_REF.supabase.co',
  key:'sb_publishable_...',        // a chave pública do projeto NOVO
  fnBase:'https://SEU_REF.supabase.co/functions/v1',
  ownerEmail:'igorgustavodelima@hotmail.com',
  ownerToken:'', ownerExp:0
};
```

**E na tela do Painel** do app (aba Painel → engrenagem/ajustes), preencha URL e chave pública — isso grava no `localStorage` do navegador e tem precedência.

Depois: publique no GitHub e teste num navegador **anônimo** (para não pegar o `localStorage` antigo).

---

## Passo 8 · Conferir tudo

```bash
bash scripts/coast-club/check-supabase.sh https://SEU_REF.supabase.co SUA_CHAVE
```

Esperado: **8 checks passando**. Depois, no app:

1. Escolher serviço → escolher horário → preencher dados → pagar
2. A página da InfinitePay deve abrir com o valor certo
3. Pagar de verdade o serviço mais barato
4. A tela deve confirmar sozinha
5. **Cancelar a reserva** de teste depois

---

## Passo 9 · Encerrar o projeto antigo

Só depois de tudo funcionando no novo:

1. Anote o que fica no antigo: nada (pode apagar)
2. **Settings → General → Delete project** (exige digitar o nome do projeto)
3. Se você criou usuário de teste lá (`teste.hacker.xyz@gmail.com`), apague antes com ele

> **Não apague antes de testar o novo.** Se algo falhar, você ainda tem o sistema funcionando no antigo.

---

## O que NÃO muda

- O **domínio** continua no Registro.br, apontando para o GitHub
- A **InfinitePay** continua na conta do Igor
- O **GitHub** pode continuar seu
- Os **clientes** não percebem nada: o endereço é o mesmo

---

## Lista de conferência

- [ ] Projeto criado na conta do Igor, região São Paulo
- [ ] Schema aplicado, `settings` com 100/1/15 e 4 funções de pagamento
- [ ] Usuário do dono criado com Auto Confirm
- [ ] E-mail inserido em `owners`
- [ ] Cadastro desligado, provedor Email **ligado**, e Save clicado
- [ ] 3 funções publicadas com `Enforce JWT` desligado (inclusive a `pay-check`)
- [ ] 5 segredos criados
- [ ] `DEFAULTS_CFG` com a URL e a chave novas
- [ ] Painel do app com a URL e a chave novas
- [ ] `check-supabase.sh` com 8/8
- [ ] Site enviado com a pasta completa (manifest + ícones + 5 fotos), nenhum 404
- [ ] Pix de teste feito e confirmado
- [ ] Reserva de teste cancelada
- [ ] Só então o projeto antigo apagado

---

## Se algo der errado

| Sintoma | Causa provável |
|---|---|
| `BOOT_ERROR` na função | voltou a usar o import `jsr:@...supabase-js` |
| Login do dono dá `422 email_provider_disabled` | desligou o provedor Email em vez do cadastro |
| Login dá `400 invalid_credentials` | senha errada **ou** e-mail não está em `owners` |
| App abre sem serviços | `DEFAULTS_CFG` ou `localStorage` ainda aponta para o banco velho |
| Pagamento abre mas não confirma | segredo `INFINITEPAY_HANDLE` errado, ou `pay-check` sem `Enforce JWT` desligado |
| Agenda mostra horário ocupado que não existe | reserva `pendente` velha: aguarde 15 min ou rode `select public.release_expired();` |
| `function book_slot(text[], ...) does not exist` | o app novo manda lista de serviços e o banco ainda tem a versão antiga de 1 serviço: aplique o schema completo |
| App mostra 8 horários por hora cheia em vez de 30 em 30 | banco sem `slot_minutes`: aplique o schema completo |
| Reservas de duração diferente se sobrepõem | faltou a constraint `bookings_no_overlap`: aplique o schema completo |
| Aluno cita "tablet não mostra instalar" | a detecção trata iPad como iOS; tablet Android cai no fluxo do Android |
