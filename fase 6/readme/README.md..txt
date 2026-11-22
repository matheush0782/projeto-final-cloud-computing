#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="final-equipeN"
POOL="pool-final"
KEEP="${KEEP:-7}"
DRY_RUN=1; YES=0
for arg in "$@"; do case "$arg" in --dry-run) DRY_RUN=1 ;; --execute) DRY_RUN=0 ;; --yes) YES=1 ;; --help) echo "Uso: $0 [--dry-run] [--execute --yes]"; echo "Padrao e --dry-run (nao apaga). Para apagar de verdade: $0 --execute --yes"; exit 0 ;; *) echo "[ERRO] Arg desconhecido: $arg" >&2; exit 2 ;; esac; done

command -v lxc >/dev/null || { echo "[ERRO] lxc nao encontrado" >&2; exit 1; }

INSTANCES=("proxy" "app" "db" "dev-proxy" "dev-app" "dev-db")
VOLUMES=("vol-db" "vol-uploads" "dev-vol-db" "dev-vol-uploads")

FAILED=0
clean_instances() {
  for inst in "${INSTANCES[@]}"; do
    echo "[INFO] Instancia $inst - mantendo $KEEP mais recentes"
    # Lista snapshots, ordena (nome tem data, entao sort funciona). Ignora erro se nao existir.
    mapfile -t snaps < <(lxc snapshot list --project "$PROJECT" "$inst" --format csv 2>/dev/null | cut -d, -f1 | sort -r || true)
    total=${#snaps[@]}
    echo "[INFO]  $inst tem $total snapshots"
    if [ "$total" -le "$KEEP" ]; then echo "[OK]  Nada a remover em $inst"; continue; fi
    to_delete=("${snaps[@]:$KEEP}")
    echo "[INFO]  Seriam removidos em $inst: ${to_delete[*]}"
    if [ "$DRY_RUN" -eq 1 ]; then continue; fi
    if [ "$YES" -ne 1 ]; then echo "[ERRO] Para executar, use --execute --yes" >&2; FAILED=1; continue; fi
    for s in "${to_delete[@]}"; do
      echo "[INFO] Removendo $inst/$s"
      if lxc snapshot delete --project "$PROJECT" "$inst" "$s"; then echo "[OK] Removido $inst/$s"; else echo "[ERRO] Falha ao remover $inst/$s" >&2; FAILED=1; fi
    done
  done
}

clean_volumes() {
  for vol in "${VOLUMES[@]}"; do
    echo "[INFO] Volume $vol - mantendo $KEEP mais recentes"
    mapfile -t snaps < <(lxc storage volume snapshot list "$POOL" "$vol" --format csv 2>/dev/null | cut -d, -f1 | sort -r || true)
    total=${#snaps[@]}
    echo "[INFO]  $vol tem $total snapshots"
    if [ "$total" -le "$KEEP" ]; then echo "[OK]  Nada a remover em $vol"; continue; fi
    to_delete=("${snaps[@]:$KEEP}")
    echo "[INFO]  Seriam removidos em $vol: ${to_delete[*]}"
    if [ "$DRY_RUN" -eq 1 ]; then continue; fi
    if [ "$YES" -ne 1 ]; then echo "[ERRO] Para executar, use --execute --yes" >&2; FAILED=1; continue; fi
    for s in "${to_delete[@]}"; do
      echo "[INFO] Removendo volume $vol/$s"
      if lxc storage volume snapshot delete "$POOL" "$vol" "$s"; then echo "[OK] Removido $vol/$s"; else echo "[ERRO] Falha ao remover $vol/$s" >&2; FAILED=1; fi
    done
  done
}

clean_instances
clean_volumes

if [ "$DRY_RUN" -eq 1 ]; then echo "[DRY-RUN] Nenhum snapshot foi apagado. Para apagar: $0 --execute --yes"; fi
if [ "$FAILED" -ne 0 ]; then echo "[ERRO] Limpeza com falhas" >&2; exit 1; fi
echo "[OK] Limpeza concluida"


Todos usam `set -Eeuo pipefail`, validam se o `lxc` existe, se o projeto existe e usam aspas nas variáveis.

## 4. Script 01 — Snapshot

**Objetivo:** criar um ponto de recuperação rápido, dentro do LXD.

**Comandos usados:**
- `lxc snapshot --project final-equipeN <instancia> <snap>`
- `lxc storage volume snapshot pool-final <volume> <snap>`

**Como funciona:**
Cria o mesmo nome de snapshot pra tudo, pra saber que é do mesmo ponto. Exemplo: `snap-20261122-180000`

Cria snapshot de 6 instâncias:
`proxy, app, db, dev-proxy, dev-app, dev-db`

E de 4 volumes:
`vol-db, vol-uploads, dev-vol-db, dev-vol-uploads`

**Exemplos:**
```bash
chmod +x script/*.sh

# Só ver o que faria, sem criar nada
./script/01-snapshot.sh --dry-run

# Criar de verdade (rápido, mas pode ficar inconsistente se o banco estiver escrevendo)
./script/01-snapshot.sh

# Criar consistente: para app e db, tira snapshot e religa
./script/01-snapshot.sh --consistent


[OK] proxy
[OK] app
[OK] db
[OK] dev-proxy
[OK] dev-app
[OK] dev-db
[OK] vol-db
[OK] vol-uploads
[OK] dev-vol-db
[OK] dev-vol-uploads
[OK] Snapshots concluidos. Ponto de recuperacao: snap-20261122-180000


lxc snapshot list --project final-equipeN app
lxc storage volume snapshot list pool-final vol-db

20261122-180000/
├── prod/instancias/prod-app-20261122-180000.tar.gz
├── prod/volumes/prod-vol-db-20261122-180000.tar.gz
├── dev/instancias/dev-app-20261122-180000.tar.gz
├── dev/volumes/dev-vol-db-20261122-180000.tar.gz
├── MANIFEST.txt
└── sha256sums.txt

# Só simular
./script/02-backup.sh --dry-run

# Fazer de verdade
./script/02-backup.sh

[OK] Backup concluido em /opt/backups/fase-6/20261122-180000
Manifesto: /opt/backups/fase-6/20261122-180000/MANIFEST.txt

cd /opt/backups/fase-6/20261122-180000 && sha256sum -c sha256sums.txt 

# Ver o que faria, sem mudar nada
./script/03-restore.sh --type instance --resource app --snapshot snap-20261122-180000 --dry-run
./script/03-restore.sh --type volume --resource vol-db --snapshot snap-20261122-180000 --dry-run

# Restaurar de verdade (vai pedir CONFIRMAR)
./script/03-restore.sh --type instance --resource app --snapshot snap-20261122-180000

# Restaurar volume
./script/03-restore.sh --type volume --resource vol-db --snapshot snap-20261122-180000

# Automatizado (só usar em script, ainda valida tudo)
./script/03-restore.sh --type instance --resource app --snapshot snap-20261122-180000 --yes

[OK] Restore concluido: instance app -> snap-20261122-180000

# Padrão: só mostra, NÃO apaga (seguro)
./script/04-limpeza.sh
./script/04-limpeza.sh --dry-run

# Apagar de verdade
./script/04-limpeza.sh --execute --yes

[INFO] Instancia app tem 10 snapshots
[INFO]  Seriam removidos em app: snap-20261101-100000 snap-20261101-090000 snap-20261101-080000
[DRY-RUN] Nenhum snapshot foi apagado.

cat /opt/backups/fase-6/20261122-180000/MANIFEST.txt
# ou
lxc snapshot list --project final-equipeN app
lxc storage volume snapshot list pool-final vol-db

./script/03-restore.sh --type volume --resource vol-db --snapshot snap-20261122-180000
./script/03-restore.sh --type volume --resource vol-uploads --snapshot snap-20261122-180000

./script/03-restore.sh --type instance --resource db --snapshot snap-20261122-180000
./script/03-restore.sh --type instance --resource app --snapshot snap-20261122-180000
./script/03-restore.sh --type instance --resource proxy --snapshot snap-20261122-180000

lxc info --project final-equipeN db
lxc info --project final-equipeN app
# tem que aparecer vol-db em db e vol-uploads em app

lxc exec --project final-equipeN db -- systemctl status mariadb
lxc exec --project final-equipeN app -- systemctl status nginx
lxc exec --project final-equipeN app -- curl -I http://10.10.10.11

lxc import --project final-equipeN prod-app-20261122-180000.tar.gz
lxc storage volume import pool-final prod-vol-db-20261122-180000.tar.gz vol-db

bash -n script/01-snapshot.sh
bash -n script/02-backup.sh
bash -n script/03-restore.sh
bash -n script/04-limpeza.sh

bash tests/test_fase6.sh

# 1. Dar permissão
chmod +x script/*.sh

# 2. Testar sem medo
./script/01-snapshot.sh --dry-run
./script/02-backup.sh --dry-run
./script/04-limpeza.sh --dry-run

# 3. Fazer de verdade
./script/01-snapshot.sh --consistent
./script/02-backup.sh

# 4. Ver se criou
lxc snapshot list --project final-equipeN app
ls -lh /opt/backups/fase-6/

# 1. Dar permissão
chmod +x script/*.sh

# 2. Testar sem medo
./script/01-snapshot.sh --dry-run
./script/02-backup.sh --dry-run
./script/04-limpeza.sh --dry-run

# 3. Fazer de verdade
./script/01-snapshot.sh --consistent
./script/02-backup.sh

# 4. Ver se criou
lxc snapshot list --project final-equipeN app
ls -lh /opt/backups/fase-6/