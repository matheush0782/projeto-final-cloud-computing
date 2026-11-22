# Fase 6 — Snapshots, Backup, Restore e Limpeza

Projeto LXD: `final-equipeN`
Pool: `pool-final`

## Objetivo

Permitir voltar no tempo se o WordPress, o banco ou um container quebrar, sem perder dados.

## Arquitetura real (não confundir)

- `proxy` (10.10.10.10 PROD / `dev-proxy` 10.10.20.10 DEV) — **Nginx** — proxy reverso
- `app` (10.10.10.11 / `dev-app` 10.10.20.11) — **Apache + WordPress**
- `db` (10.10.10.12 / `dev-db` 10.10.20.12) — **MariaDB**

Volumes (onde estão os dados de verdade):
- `vol-db` → `db:/var/lib/mysql`
- `vol-uploads` → `app:/var/www/html/wp-content/uploads`
- `dev-vol-db` → `dev-db:/var/lib/mysql`
- `dev-vol-uploads` → `dev-app:/var/www/html/wp-content/uploads`

Snapshot de instância NÃO inclui volume customizado. Por isso sempre fazemos os dois.

## Estrutura



## Pré-requisitos

- `lxc` instalado, usuário com acesso ao LXD
- Projeto `final-equipeN` existente, pool `pool-final`
- Permissão: `chmod +x scripts/*.sh`
- Variáveis opcionais: `PROJECT=final-equipeN POOL=pool-final BACKUP_BASE=/opt/backups/fase-6`

## 01-snapshot.sh

Cria snapshot de 6 instâncias + 4 volumes com o mesmo nome `snap-YYYYMMDD-HHMMSS`.

```bash
./scripts/01-snapshot.sh --dry-run
./scripts/01-snapshot.sh --consistent

lxc snapshot list --project final-equipeN app
lxc storage volume snapshot list --project final-equipeN pool-final vol-db