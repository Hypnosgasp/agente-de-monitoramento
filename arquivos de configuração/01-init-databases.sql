-- Executado automaticamente pelo Postgres apenas na primeira inicialização do volume.
-- Cria os 3 bancos separados: um para o n8n, um para a Evolution API,
-- e um para as tabelas próprias do projeto (incidents, hosts, etc.).

CREATE DATABASE n8n;
CREATE DATABASE evolution;
CREATE DATABASE monitoring;
