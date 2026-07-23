# Arquitetura Técnica — Agente de Monitoramento Zabbix → WhatsApp

## Visão geral do fluxo

```
Zabbix (local)
   │  webhook (media type customizado)
   ▼
n8n (local) — Webhook Trigger
   │
   ▼
Normalização do payload
   │
   ▼
Consulta ao Postgres (existe incidente com esse trigger/event id?)
   │
   ├── Novo problema (PROBLEM) ──► Grava incidente ──► Avalia severidade ──► Decide notificar?
   │                                                                              │
   │                                                                    ┌─────────┴─────────┐
   │                                                                   Sim                  Não
   │                                                                    │                    │
   │                                                          Fila/agrupamento        Só registra no banco
   │                                                                    │
   │                                                          Formata mensagem
   │                                                                    │
   │                                                          Evolution API → WhatsApp
   │                                                                    │
   │                                                          Grava em notifications_sent
   │
   └── Resolução (RESOLVED) ──► Atualiza status do incidente ──► Notifica "resolvido"
```

---

## 1. Banco de dados (Postgres)

### Tabela `hosts`
Cadastro simples dos equipamentos monitorados (pode ser populada automaticamente a partir dos primeiros eventos recebidos, sem precisar de cadastro manual prévio).

| Campo | Tipo | Descrição |
|---|---|---|
| `id` | serial (PK) | identificador interno |
| `zabbix_hostid` | text | ID do host no Zabbix |
| `nome` | text | nome do host (ex: SRV-APP-01) |
| `ip` | text | IP do equipamento |
| `criado_em` | timestamp | primeira vez que o host apareceu num evento |

### Tabela `incidents`
O coração do sistema — representa o **estado atual** de cada problema. É essa tabela que resolve a deduplicação e o histerese (não notificar de novo o que já está aberto).

| Campo | Tipo | Descrição |
|---|---|---|
| `id` | serial (PK) | identificador interno |
| `zabbix_eventid` | text (unique) | ID do evento de PROBLEM no Zabbix — chave de deduplicação |
| `zabbix_triggerid` | text | ID do trigger correspondente |
| `host_id` | FK → hosts | equipamento afetado |
| `severidade` | text | Not classified / Warning / Average / High / Disaster |
| `metrica` | text | ex: "CPU", "Memória", "Disco" |
| `valor_atual` | text | valor no momento do disparo |
| `limite_configurado` | text | threshold que foi ultrapassado |
| `descricao` | text | descrição do problema (nome do trigger) |
| `status` | text | `aberto` / `resolvido` |
| `notificado` | boolean | se já foi enviada mensagem no WhatsApp |
| `grupo_correlacao_id` | text (nullable) | preenchido quando o Zabbix indica que esse trigger é dependente de outro (permite agrupar na mensagem) |
| `iniciado_em` | timestamp | hora do PROBLEM |
| `resolvido_em` | timestamp (nullable) | hora do RESOLVED |
| `dashboard_url` | text | link do Grafana |
| `evento_url` | text | link do evento no Zabbix |

### Tabela `incident_events`
Log bruto de tudo que chegou do Zabbix — inclusive o que foi filtrado e não gerou notificação. É essa tabela que atende ao requisito de **histórico completo**, mesmo dos eventos irrelevantes.

| Campo | Tipo | Descrição |
|---|---|---|
| `id` | serial (PK) | identificador interno |
| `incident_id` | FK → incidents (nullable) | vínculo com o incidente, se aplicável |
| `payload_bruto` | jsonb | payload original recebido do Zabbix, sem tratamento |
| `recebido_em` | timestamp | quando o n8n recebeu |
| `foi_notificado` | boolean | se esse evento específico gerou mensagem |

### Tabela `notifications_sent`
Registro do que efetivamente foi enviado ao grupo — separado da tabela de incidentes porque um mesmo incidente pode gerar mais de uma mensagem (abertura + resolução, ou atualização de agravamento).

| Campo | Tipo | Descrição |
|---|---|---|
| `id` | serial (PK) | identificador interno |
| `incident_id` | FK → incidents | qual incidente gerou essa mensagem |
| `tipo` | text | `abertura` / `resolucao` / `resumo_agrupado` |
| `mensagem_enviada` | text | conteúdo exato enviado |
| `enviado_em` | timestamp | quando foi enviado |
| `status_envio` | text | sucesso / falha (útil se a Evolution API cair) |

---

## 2. Configuração no lado do Zabbix (pré-requisito)

Antes do n8n processar qualquer coisa, o Zabbix precisa estar configurado para:

1. **Media type customizado do tipo Webhook**, apontando para a URL do webhook do n8n (rede interna, sem exposição externa).
2. **Macros no payload** incluindo pelo menos: `{EVENT.ID}`, `{TRIGGER.ID}`, `{HOST.NAME}`, `{HOST.IP}`, `{TRIGGER.SEVERITY}`, `{TRIGGER.NAME}`, `{ITEM.VALUE}`, `{TRIGGER.STATUS}` (PROBLEM/OK), `{EVENT.DATE}`, `{EVENT.TIME}`, `{TRIGGER.URL}` (para o link do dashboard, se configurado).
3. **Trigger dependencies** configuradas entre hosts relacionados (ex: hosts atrás de um switch dependem do trigger de "switch offline") — é isso que alimenta o `grupo_correlacao_id` na tabela `incidents`.
4. **Actions** no Zabbix habilitando esse media type tanto para eventos de problema quanto de recuperação (recovery), para que o `RESOLVED` também dispare o webhook.

---

## 3. Fluxo no n8n (sequência de nodes)

1. **Webhook Trigger** — recebe o POST do Zabbix.
2. **Normalize (Function/Set node)** — extrai os campos do payload bruto para um formato interno padronizado.
3. **Postgres — Insert em `incident_events`** — grava o evento bruto imediatamente (garante histórico mesmo se algo falhar depois).
4. **IF — Tipo de evento (PROBLEM ou RESOLVED)**:
   - **Se PROBLEM:**
     a. **Postgres — Upsert em `incidents`** usando `zabbix_eventid` como chave de deduplicação.
     b. **IF — Severidade atinge o limiar de notificação** (ex: a partir de "Average"/80%, conforme calibrado).
     c. **IF — `grupo_correlacao_id` já tem notificação pendente na fila** → agrupa em vez de mandar mensagem separada.
     d. **Format Message (Function node)** — monta o texto no formato já definido (🚨 severidade, 📍 host, etc.).
     e. **HTTP Request → Evolution API** — envia ao grupo do WhatsApp.
     f. **Postgres — Insert em `notifications_sent`**.
   - **Se RESOLVED:**
     a. **Postgres — Update em `incidents`** (status = resolvido, `resolvido_em` = agora).
     b. **IF — o incidente original tinha sido notificado** (`notificado = true`) → só nesse caso avisa a resolução (evita avisar resolução de algo que nunca foi notificado como problema).
     c. **Format Message** (variação "✅ Resolvido").
     d. **HTTP Request → Evolution API**.
     e. **Postgres — Insert em `notifications_sent`**.

5. **Mecanismo de fila/rate limit** — implementado como um segundo fluxo agendado (n8n *Schedule Trigger*, ex: a cada 30-60s):
   - Consulta incidentes com `notificado = false` que chegaram nesse intervalo.
   - Se houver mais de um com o mesmo `grupo_correlacao_id`, monta **uma mensagem-resumo** em vez de várias.
   - Envia e marca todos como notificados.
   - Isso evita tanto o flood no grupo quanto múltiplas chamadas simultâneas para a Evolution API.

---

## 4. Ponto de entrada futuro da IA (Llama)

Local recomendado para inserir no fluxo, sem redesenhar nada: **entre o "Format Message" e o "HTTP Request → Evolution API"**, como uma etapa opcional que:
- Recebe os dados estruturados do(s) incidente(s) agrupado(s).
- Gera um resumo em linguagem natural (útil principalmente quando há vários incidentes correlacionados).
- Se a chamada ao Llama falhar ou demorar demais, o fluxo cai de volta no template fixo — a IA deve ser um *enhancement*, nunca uma dependência crítica para o envio da mensagem.

---

## 5. Resumo das decisões já fechadas incorporadas neste desenho

- Fonte única de alertas: **Zabbix** (sem Grafana como origem de evento).
- Hospedagem: **servidor local**, webhook interno (sem exposição pública).
- Notificação: **grupo único** do WhatsApp via **Evolution API**.
- Deduplicação: por **`zabbix_eventid`** no Postgres.
- Agrupamento de rajada: por **trigger dependency** do Zabbix (`grupo_correlacao_id`).
- IA: **Llama self-hosted**, como camada opcional de resumo, não crítica ao fluxo.
