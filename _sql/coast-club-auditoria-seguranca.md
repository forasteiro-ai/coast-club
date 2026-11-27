# Auditoria de segurança — Coast Club & Barber Shop

**Data:** 26/11/2026 · **Alvo:** https://forasteiro-ai.github.io/coast-club/ + projeto Supabase `fjxrkfliobdzvrwqnmme`
**Método:** testes ativos contra produção, com a chave pública do site — o mesmo acesso que qualquer visitante tem.

---

## Veredito

**Nenhuma falha que exponha dados de cliente.** O que existe são três portas abertas que permitem *abuso* (encher a agenda, gastar o e-mail do Supabase), não vazamento. Duas delas têm correção no dashboard, sem tocar em código.

| Item | Risco | Ação |
|---|---|---|
| Signup aberto | **Alto** (abuso, não vazamento) | Desligar no dashboard |
| Sem limite de reservas | **Médio** | Edge Function ou captcha |
| Sem limite de login visível | **Baixo** | Conferir Rate Limits |
| Leaked Password Protection | **Baixo** | 1 clique |
| Duplicidade de GRANTs | Cosmético | Opcional |

---

## 1. Signup aberto — RISCO ALTO (abuso, não vazamento)

**Teste:** criei uma conta real com `POST /auth/v1/signup` usando só a chave pública.
**Resultado:** `HTTP 200` — conta `teste.hacker.xyz@gmail.com` criada no projeto.

**O que isso permite:**
- Criar contas ilimitadas que ficam paradas em `auth.users`.
- **O ataque real:** cada signup dispara um e-mail do Supabase, e o serviço padrão tem limite de **2 e-mails por hora**. Dois cadastros falsos e o e-mail de *recuperação de senha do Igor* para de sair por uma hora.

**O que NÃO permite:** os usuários criados ficam com e-mail não confirmado. Testei o login de um deles: `HTTP 400 email_not_confirmed`. Sem sessão, o RLS bloqueia tudo. **Não há acesso a dado nenhum.**

**Correção (dashboard, 1 minuto):**
Authentication → Sign In / Providers → Email → desmarcar **Allow new users to sign up** → Save.

> Depois disso, só o usuário do Igor existe. Ninguém cria conta pelo site — e o site não precisa: o cliente agenda sem login.

---

## 2. Sem limite de reservas falsas — RISCO MÉDIO

**Teste:** `book_slot` aceita reserva de qualquer visitante, sem login. O índice único impede duas reservas no mesmo horário, então não há duplicidade — mas **nada impede** alguém ocupar os 8 horários de todos os dias futuros com nomes inventados.

**Impacto:** a agenda do Igor enche de falso e os clientes reais não conseguem marcar. É o ataque mais provável na prática, porque é trivial.

**Correção:** rate limit por WhatsApp e por IP numa Edge Function (o Supabase conta requisições), ou captcha invisível. ~1h de trabalho.

---

## 3. Login sem limite de tentativas visível — RISCO BAIXO

**Teste:** 10 tentativas de senha errada seguidas → 10 respostas `400`, nenhuma bloqueada.

O Supabase tem rate limit interno configurável. Como a senha do Igor é forte, o risco real é baixo — mas vale conferir em Authentication → Rate Limits.

---

## 4. Leaked Password Protection — RISCO BAIXO, 1 clique

Authentication → Sign In / Providers → Password Security → ativar **Leaked Password Protection**.
Compara a senha com vazamentos conhecidos (HaveIBeenPwned). Gratuito.

---

## 5. Duplicidade de GRANTs — cosmético

O schema roda `grant all on public.services to anon, authenticated` e, mais abaixo, apaga e recria as policies de RLS. O resultado final é correto — o RLS decide — mas o `grant all` para `anon` em tabelas como `bookings` fica inerte e confunde quem lê o SQL depois.

Testado: `bookings`, `owners`, `settings` e `coupons` devolvem `401 permission denied` para visitante. **Nada vaza.**
Limpeza opcional (não urgente): `revoke all on public.bookings, public.owners, public.coupons, public.settings from anon;`

---

## O que está comprovadamente certo

Testado agora contra produção:

- ✓ `bookings` → 401 para visitante · nome, WhatsApp e e-mail dos clientes protegidos
- ✓ `settings` → 401 · o PIN não vaza
- ✓ `owners` → 401 · e-mails de donos protegidos
- ✓ `coupons` → 401 · o COAST10 é validado só no servidor
- ✓ `settings_public` expõe apenas: nome da loja, Instagram, nome/WhatsApp do dono (públicos por natureza) e horários
- ✓ `busy_slots` expõe apenas data e hora — nunca quem agendou
- ✓ Escrita sem login: 401 em `services` e `settings`
- ✓ **Nenhum segredo no repositório** — conferi os 3 commits: só a chave `sb_publishable_...`, nenhuma `sb_secret_`, nenhum `service_role`
- ✓ **Sem XSS** — testei nome de cliente com `<script>` e `onmouseover`: renderizou como texto puro, zero elementos injetados. O `esc()` está aplicado nos 42 pontos.
- ✓ Fonte local idêntica ao que está no ar (nenhuma edição perdida no deploy)
- ✓ Chave pública do site válida e funcionando

---

## Próximo passo recomendado

1. Desligar o signup no dashboard (1 minuto) — fecha o risco real.
2. Ativar Leaked Password Protection (1 minuto).
3. Rate limit na reserva — só antes de divulgar o app publicamente, porque hoje ninguém sabe que ele existe.
