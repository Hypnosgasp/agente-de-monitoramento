# Ambiente Docker — Agente de Monitoramento

Este pacote sobe os 4 serviços da arquitetura: **Postgres**, **Redis**, **n8n** e **Evolution API**, todos na mesma rede Docker interna (`monitoring_net`), isolados do resto da internet exceto pelo que for explicitamente exposto.

## Arquivos deste pacote

- `docker-compose.yml` — definição dos serviços.
- `.env.example` — modelo de variáveis de ambiente (senhas, chaves, URLs).
- `init-db/01-init-databases.sql` — cria os 3 bancos necessários (`n8n`, `evolution`, `monitoring`) na primeira subida.

## Passo a passo

### 1. Preparar o `.env`

```bash
cp .env.example .env
```

Edite o `.env` e substitua **todos** os valores de exemplo:
- Senhas do Postgres.
- `N8N_ENCRYPTION_KEY` — gere com `openssl rand -hex 32`.
- `N8N_HOST` e `N8N_WEBHOOK_URL` — coloque o IP real do servidor local (ex: `192.168.0.10`). É esse IP que o Zabbix vai usar para mandar o webhook, então precisa ser um IP fixo dentro da rede.
- `EVOLUTION_API_KEY` — gere qualquer string aleatória forte, ela funciona como senha de acesso à API.

### 2. Subir os containers

```bash
docker compose up -d
```

Na primeira subida, o Postgres executa automaticamente o script em `init-db/`, criando os 3 bancos.

### 3. Verificar se tudo subiu

```bash
docker compose ps
```

Todos os 4 serviços devem aparecer como `running`/`healthy`.

### 4. Acessar o n8n

Abra `http://<IP_DO_SERVIDOR>:5678` no navegador. Vai pedir o usuário/senha definidos em `N8N_BASIC_AUTH_USER` / `N8N_BASIC_AUTH_PASSWORD`.

### 5. Conectar o número de WhatsApp na Evolution API

A Evolution API precisa de uma "instância" conectada via QR code. Isso é feito chamando a própria API (não tem interface gráfica pronta por padrão — algumas versões têm um manager web, outras exigem chamada HTTP direta). O fluxo básico é:

1. Criar uma instância via requisição HTTP à Evolution API (endpoint de criação de instância, usando o `EVOLUTION_API_KEY` no header).
2. A API retorna um QR code (imagem base64 ou endpoint de imagem).
3. Escanear esse QR code com o WhatsApp do número virtual (Configurações → Aparelhos conectados → Conectar um aparelho).
4. A sessão fica ativa enquanto o container não for reiniciado/perder os dados do volume `evolution_instances`.

Quando chegarmos na etapa do fluxo do n8n, monto com você a chamada exata (endpoint, payload) para criar essa instância e testar o envio de uma mensagem de teste para o grupo.

## Notas de segurança

- **Não exponha as portas 5432 (Postgres), 5678 (n8n) ou 8080 (Evolution API) para a internet.** Elas devem ficar acessíveis só dentro da rede local. Se precisar acessar de fora (ex: você em home office), use VPN para entrar na rede local, não abra porta direto no roteador/firewall.
- Troque **todas** as senhas de exemplo do `.env` antes de subir em produção.
- Faça backup periódico do volume `postgres_data` — é onde fica todo o histórico de incidentes e a configuração do próprio n8n.

## Próximo passo

Com o ambiente no ar, o próximo passo natural é o **script SQL das tabelas do projeto** (`incidents`, `hosts`, `incident_events`, `notifications_sent`) dentro do banco `monitoring`, seguido da criação do fluxo no n8n.
