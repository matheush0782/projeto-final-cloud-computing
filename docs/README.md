# Fase 6 — Snapshots, Backup, Restore e Limpeza

Projeto LXD: `final-equipeN`
Pool: `pool-final`

## Objetivo

Permitir voltar no tempo se o WordPress, o banco ou um container quebrar, sem perder dados. Snapshot é rápido e fica dentro do LXD. Backup é exportado para `.tar.gz` fora do LXD.

## Arquitetura real

- `proxy` (PROD 10.10.10.10 / `dev-proxy` 10.10.20.10) — **Nginx** — proxy reverso
- `app` (PROD 10.10.10.11 / `dev-app` 10.10.20.11) — **Apache + WordPress**
- `db` (PROD 10.10.10.12 / `dev-db` 10.10.20.12) — **MariaDB**

Volumes:
- `vol-db` → `db:/var/lib/mysql`
- `vol-uploads` → `app:/var/www/html/wp-content/uploads`
- `dev-vol-db` → `dev-db:/var/lib/mysql`
- `dev-vol-uploads` → `dev-app:/var/www/html/wp-content/uploads`

Snapshot de instância NÃO inclui volume customizado. Por isso sempre fazemos os dois.

## Estrutura de arquivos



## Pré-requisitos

- `lxc` instalado, acesso ao LXD, projeto `final-equipeN`, pool `pool-final`
- `chmod +x scripts/*.sh`
- Variáveis opcionais: `PROJECT`, `POOL`, `BACKUP_BASE`

## 01-snapshot.sh

Parâmetros: `--dry-run`, `--consistent`

```bash
./scripts/01-snapshot.sh --dry-run
./scripts/01-snapshot.sh --consistent

lxc snapshot list --project final-equipeN app
lxc storage volume snapshot list --project final-equipeN pool-final vol-db