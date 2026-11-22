#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="${PROJECT:-final-equipeN}"
POOL="${POOL:-pool-final}"
TS="$(date +%Y%m%d-%H%M%S)"
SNAP="snap-${TS}"

INSTANCES=("proxy" "app" "db" "dev-proxy" "dev-app" "dev-db")
VOLUMES=("vol-db" "vol-uploads" "dev-vol-db" "dev-vol-uploads")
CONSUMERS=("app" "db" "dev-app" "dev-db")

DRY_RUN=0; CONSISTENT=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --consistent) CONSISTENT=1 ;;
    --help) echo "Uso: $0 [--dry-run] [--consistent]"; exit 0 ;;
    *) echo "[ERRO] Arg desconhecido: $arg" >&2; exit 2 ;;
  esac
done

command -v lxc >/dev/null || { echo "[ERRO] lxc nao encontrado" >&2; exit 1; }

# CORRECAO REVISAO 7.5: usa if, nao rc=$? (set -e mataria antes)
# Retorna Running / Stopped / ERROR
get_state() {
  local out
  if out="$(lxc info --project "$PROJECT" "$1" 2>&1)"; then
    :
  else
    echo "[ERRO] Falha ao consultar $1: $out" >&2
    echo "ERROR"
    return 1
  fi
  if echo "$out" | grep -qi "^Status:.*Running"; then echo "Running"; return 0; fi
  if echo "$out" | grep -qi "^Status:.*Stopped"; then echo "Stopped"; return 0; fi
  echo "[ERRO] Estado desconhecido em $1" >&2
  echo "ERROR"
  return 1
}

declare -A WAS_RUNNING=()
restore_state() {
  for inst in "${CONSUMERS[@]}"; do
    if [[ "${WAS_RUNNING[$inst]:-}" == "Running" ]]; then
      echo "[INFO] Religando $inst (estava Running antes)"
      lxc start --project "$PROJECT" "$inst" || echo "[ERRO] Falha ao religar $inst" >&2
    fi
  done
}
trap restore_state EXIT

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[DRY-RUN] Projeto: $PROJECT Pool: $POOL Snapshot: $SNAP"
  for i in "${INSTANCES[@]}"; do echo "[DRY-RUN] lxc snapshot --project \"$PROJECT\" $i $SNAP"; done
  for v in "${VOLUMES[@]}"; do echo "[DRY-RUN] lxc storage volume snapshot --project \"$PROJECT\" $POOL $v $SNAP"; done
  trap - EXIT; exit 0
fi

if [ "$CONSISTENT" -eq 1 ]; then
  echo "[INFO] Modo consistente: registrando estado original"
  for inst in "${CONSUMERS[@]}"; do
    st="$(get_state "$inst")" || { echo "[ERRO] Abortando, nao foi possivel determinar estado de $inst" >&2; exit 1; }
    WAS_RUNNING["$inst"]="$st"; echo "[INFO] $inst = $st"
  done
  for inst in "${CONSUMERS[@]}"; do
    if [[ "${WAS_RUNNING[$inst]}" == "Running" ]]; then
      if ! lxc stop --project "$PROJECT" "$inst"; then echo "[ERRO] Falha ao parar $inst. Abortando." >&2; exit 1; fi
    fi
  done
fi

FAILED=0
for inst in "${INSTANCES[@]}"; do
  if lxc snapshot --project "$PROJECT" "$inst" "$SNAP"; then echo "[OK] $inst"; else echo "[ERRO] Falha snapshot $inst" >&2; FAILED=1; fi
done
for vol in "${VOLUMES[@]}"; do
  if lxc storage volume snapshot --project "$PROJECT" "$POOL" "$vol" "$SNAP"; then echo "[OK] $vol"; else echo "[ERRO] Falha snapshot volume $vol" >&2; FAILED=1; fi
done
[ "$FAILED" -eq 0 ] || { echo "[ERRO] Snapshot com FALHAS. Ponto $SNAP incompleto." >&2; exit 1; }
echo "[OK] Snapshots concluidos. Ponto: $SNAP"