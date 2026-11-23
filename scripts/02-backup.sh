#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="${PROJECT:-final-equipeN}"
POOL="${POOL:-pool-final}"
BASE="${BACKUP_BASE:-/opt/backups/fase-6}"
TS="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
DEST="$BASE/$TS"

INSTANCES_PROD=("proxy" "app" "db")
INSTANCES_DEV=("dev-proxy" "dev-app" "dev-db")
VOLUMES_PROD=("vol-db" "vol-uploads")
VOLUMES_DEV=("dev-vol-db" "dev-vol-uploads")
CONSUMERS=("app" "db" "dev-app" "dev-db")

DRY_RUN=0
for arg in "$@"; do case "$arg" in --dry-run) DRY_RUN=1 ;; --help) echo "Uso: $0 [--dry-run]"; exit 0 ;; *) echo "[ERRO] Arg desconhecido: $arg" >&2; exit 2 ;; esac; done

command -v lxc >/dev/null || { echo "[ERRO] lxc nao encontrado" >&2; exit 1; }
command -v sha256sum >/dev/null || { echo "[ERRO] sha256sum nao encontrado" >&2; exit 1; }

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
  echo "ERROR"; return 1
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
  echo "[DRY-RUN] Backup seria criado em $DEST"
  echo "[DRY-RUN] Pararia consumidores, exportaria instancias com --instance-only + volumes separados"
  trap - EXIT; exit 0
fi

if [ -e "$DEST" ]; then echo "[ERRO] Destino $DEST ja existe. Abortando." >&2; exit 1; fi
mkdir -p "$DEST/prod/instancias" "$DEST/prod/volumes" "$DEST/dev/instancias" "$DEST/dev/volumes" || { echo "[ERRO] Falha ao criar $DEST" >&2; exit 1; }

echo "[INFO] Registrando estado e parando consumidores"
for inst in "${CONSUMERS[@]}"; do
  st="$(get_state "$inst")" || { echo "[ERRO] Abortando, nao foi possivel determinar estado de $inst" >&2; exit 1; }
  WAS_RUNNING["$inst"]="$st"
done
for inst in "${CONSUMERS[@]}"; do
  if [[ "${WAS_RUNNING[$inst]}" == "Running" ]]; then
    lxc stop --project "$PROJECT" "$inst" || { echo "[ERRO] Falha ao parar $inst. Abortando." >&2; exit 1; }
  fi
done

MANIFEST="$DEST/MANIFEST.txt"
{ echo "Backup Fase 6"; echo "Data: $TS"; echo "Projeto: $PROJECT"; echo "Pool: $POOL"; echo "Destino: $DEST"; echo "---"; } > "$MANIFEST"
FAILED=0

export_inst() {
  local env="$1" inst="$2" out="$DEST/$env/instancias/${env}-${inst}-${TS}.tar.gz"
  echo "[INFO] Exportando instancia $inst com --instance-only"
  if lxc export --project "$PROJECT" --instance-only "$inst" "$out" && [ -s "$out" ]; then
    echo "[OK] instancia $inst -> $out" >> "$MANIFEST"; echo "[OK] $inst"
  else echo "[ERRO] Falha export $inst" >&2; echo "[FALHA] instancia $inst" >> "$MANIFEST"; FAILED=1; fi
}
export_vol() {
  local env="$1" vol="$2" out="$DEST/$env/volumes/${env}-${vol}-${TS}.tar.gz"
  echo "[INFO] Exportando volume $vol"
  if lxc storage volume export --project "$PROJECT" "$POOL" "$vol" "$out" && [ -s "$out" ]; then
    echo "[OK] volume $vol -> $out" >> "$MANIFEST"; echo "[OK] $vol"
  else echo "[ERRO] Falha export volume $vol" >&2; echo "[FALHA] volume $vol" >> "$MANIFEST"; FAILED=1; fi
}

for i in "${INSTANCES_PROD[@]}"; do export_inst "prod" "$i"; done
for i in "${INSTANCES_DEV[@]}"; do export_inst "dev" "$i"; done
for v in "${VOLUMES_PROD[@]}"; do export_vol "prod" "$v"; done
for v in "${VOLUMES_DEV[@]}"; do export_vol "dev" "$v"; done

(cd "$DEST" && find . -name "*.tar.gz" -exec sha256sum {} + > sha256sums.txt) || { echo "[ERRO] Falha ao gerar checksums" >&2; FAILED=1; }
if [ "$FAILED" -eq 0 ]; then
  if (cd "$DEST" && sha256sum -c sha256sums.txt >/dev/null); then echo "[OK] Checksums validados"; else echo "[ERRO] Checksum nao confere" >&2; FAILED=1; fi
fi
[ "$FAILED" -eq 0 ] || { echo "[ERRO] Backup com FALHAS. Veja $MANIFEST" >&2; exit 1; }
echo "[OK] Backup concluido em $DEST"
