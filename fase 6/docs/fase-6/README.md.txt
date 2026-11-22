# Fase 6 — Snapshots, Backup, Restore e Limpeza

Projeto LXD: `final-equipeN`
Pool: `pool-final`

## Objetivo

Permitir voltar no tempo se o WordPress, o banco ou um container quebrar, sem perder dados. Snapshot é rápido e fica dentro do LXD. Backup é exportado para `.tar.gz` fora do LXD e pode ser levado para outro lugar.

## Arquitetura real

- `proxy` (PROD 10.10.10.10 / `dev-proxy` 10.10.20.10) — **Nginx** — proxy reverso
- `app` (PROD 10.10.10.11 / `dev-app` 10.10.20.11) — **Apache + WordPress**
- `db` (PROD 10.10.10.12 / `dev-db` 10.10.20.12) — **MariaDB**

Volumes (onde estão os dados de verdade):
- `vol-db` → `db:/var/lib/mysql`
- `vol-uploads` → `app:/var/www/html/wp-content/uploads`
- `dev-vol-db` → `dev-db:/var/lib/mysql`
- `dev-vol-uploads` → `dev-app:/var/www/html/wp-content/uploads`

## Diferença: snapshot de instância vs volume

- Snapshot de instância (`lxc snapshot`) salva o container, mas **NÃO** inclui volume customizado anexado.
- Snapshot de volume (`lxc storage volume snapshot`) salva o disco de dados.
- Por isso sempre fazemos os dois com o mesmo nome `snap-YYYYMMDD-HHMMSS`.

## Estrutura de arquivos
