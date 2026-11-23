#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="${PROJECT:-final-equipeN}"
POOL="${POOL:-pool-final}"
KEEP="${KEEP:-7}"
DRY_RUN=1; YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --execute) DRY_RUN=0 ;;
    --yes) YES=1 ;;
    --help) echo "Uso: $0 [--dry-run] [--execute --yes]"; echo "KEEP: KEEP=10 $0 --dry-run"; exit 0 ;;
    *) echo "[ERRO] Arg desconhecido: $arg" >&2; exit 2 ;;
  esac
done

if ! [[ "$KEEP" =~ ^[0-9]+$ ]]; then echo "[ERRO] KEEP deve ser inteiro >=0, recebido: $KEEP" >&2; exit 2; fi
command -v lxc >/dev/null || { echo "[ERRO] lxc nao encontrado" >&2; exit 1; }

INSTANCES=("proxy" "app" "db" "dev-proxy" "dev-app" "dev-db")
VOLUMES=("vol-db" "vol-uploads" "dev-vol-db" "dev-vol-uploads")
FAILED=0

list_snaps_to_file() {
  local kind="$1" name="$2" outfile="$3" errfile="$4"
  if [ "$kind" = "instance" ]; then
    if ! lxc snapshot list --project "$PROJECT" "$name" --format csv > "$outfile" 2> "$errfile"; then
      echo "[ERRO] Falha ao listar snapshots de $name:" >&2; cat "$errfile" >&2; return 1
    fi
  else
    if ! lxc storage volume snapshot list --project "$PROJECT" "$POOL" "$name" --format csv > "$outfile" 2> "$errfile"; then
      echo "[ERRO] Falha ao listar snapshots do volume $name:" >&2; cat "$errfile" >&2; return 1
    fi
  fi
  return 0
}

clean_one() {
  local kind="$1" name="$2"
  local tmp errf
  tmp="$(mktemp)"; errf="$(mktemp)"
  echo "[INFO] $kind $name - mantendo $KEEP mais recentes"
  if ! list_snaps_to_file "$kind" "$name" "$tmp" "$errf"; then
    echo "[ERRO] Abortando limpeza de $name - consulta falhou, nao vou assumir lista vazia" >&2
    FAILED=1; rm -f "$tmp" "$errf"; return 1
  fi
  local snaps=() line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    snaps+=("$(echo "$line" | cut -d, -f1)")
  done < "$tmp"
  rm -f "$tmp" "$errf"
  IFS=$'\n' snaps=($(printf "%s\n" "${snaps[@]}" | sort -r)); unset IFS
  local total=${#snaps[@]}
  echo "[INFO]  $name tem $total snapshots"
  if [ "$total" -le "$KEEP" ]; then echo "[OK]  Nada a remover em $name"; return 0; fi
  local to_delete=("${snaps[@]:$KEEP}")
  echo "[INFO]  Preservados: ${snaps[@]:0:$KEEP}"
  echo "[INFO]  Seriam removidos: ${to_delete[*]}"
  if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
  if [ "$YES" -ne 1 ]; then echo "[ERRO] Use --execute --yes para apagar de verdade" >&2; FAILED=1; return 1; fi
  for s in "${to_delete[@]}"; do
    if [ "$kind" = "instance" ]; then
      if lxc snapshot delete --project "$PROJECT" "$name" "$s"; then echo "[OK] Removido $name/$s"; else echo "[ERRO] Falha remover $name/$s" >&2; FAILED=1; fi
    else
      if lxc storage volume snapshot delete --project "$PROJECT" "$POOL" "$name" "$s"; then echo "[OK] Removido volume $name/$s"; else echo "[ERRO] Falha remover $name/$s" >&2; FAILED=1; fi
    fi
  done
}

for i in "${INSTANCES[@]}"; do clean_one "instance" "$i" || true; done
for v in "${VOLUMES[@]}"; do clean_one "volume" "$v" || true; done

if [ "$DRY_RUN" -eq 1 ]; then echo "[DRY-RUN] Nenhum snapshot apagado. Para apagar: $0 --execute --yes"; fi
[ "$FAILED" -eq 0 ] || { echo "[ERRO] Limpeza com falhas" >&2; exit 1; }
echo "[OK] Limpeza concluida"

./scripts/04-limpeza.sh --dry-run
KEEP=10 ./scripts/04-limpeza.sh --dry-run
./scripts/04-limpeza.sh --execute --yes

# 1. Restaurar volumes primeiro
./scripts/03-restore.sh --mode snapshot --type volume --resource vol-db --snapshot snap-20261122-180000
./scripts/03-restore.sh --mode snapshot --type volume --resource vol-uploads --snapshot snap-20261122-180000
# 2. Restaurar instancias
./scripts/03-restore.sh --mode snapshot --type instance --resource db --snapshot snap-20261122-180000
./scripts/03-restore.sh --mode snapshot --type instance --resource app --snapshot snap-20261122-180000
./scripts/03-restore.sh --mode snapshot --type instance --resource proxy --snapshot snap-20261122-180000
# 3. Verificar
lxc exec --project final-equipeN db -- systemctl status mariadb
lxc exec --project final-equipeN proxy -- systemctl status nginx
lxc exec --project final-equipeN app -- systemctl status apache2