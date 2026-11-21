#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2153
# common.sh fornece as funções e variáveis de configuração consumidas abaixo.
# shellcheck disable=SC1091,SC2153
# shellcheck source=scripts/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ajuda() {
  cat <<'TXT'
Uso: ENV=prod ./scripts/destroy.sh [--dry-run] [--volumes] [--yes]
     ENV=dev  ./scripts/destroy.sh [--dry-run] [--volumes] [--yes]
Opções:
  --env prod|dev                    Seleciona o ambiente (padrão: ENV ou prod).
  --dry-run                         Mostra o plano exato; não consulta nem altera LXD.
  --yes                             Confirma somente instâncias, discos raiz e snapshots.
  --volumes                         Inclui exatamente os dois volumes deste ambiente.
  --confirm-volumes PROJETO/ENV     Confirma volumes em execução não interativa.
  -h, --help                        Mostra esta ajuda.

Sem --volumes, os volumes do banco e uploads são preservados. Com --volumes,
existe uma confirmação EXTRA: em terminal, digite exatamente
APAGAR-VOLUMES:PROJETO/ENV; sem terminal, use --yes e
--confirm-volumes PROJETO/ENV. Token errado ou --confirm-volumes sem
--volumes aborta antes de qualquer exclusão.

Não são removidas redes, profiles, pool, projeto ou certificados/chaves TLS
locais em conf/tls/ENV. Faça backup dos volumes antes de apagar dados.
TXT
}

APAGAR_VOLUMES=false
SIM=false
DRY_RUN=false
CONFIRM_VOLUMES=''
while (($#)); do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || falhar 'Falta o valor de --env.'
      ENV="$2"
      shift 2
      ;;
    --volumes)
      APAGAR_VOLUMES=true
      shift
      ;;
    --confirm-volumes)
      [[ $# -ge 2 ]] || falhar 'Falta o valor de --confirm-volumes.'
      CONFIRM_VOLUMES="$2"
      shift 2
      ;;
    --yes)
      SIM=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      ajuda
      exit 0
      ;;
    *)
      falhar "Parâmetro desconhecido: $1"
      ;;
  esac
done

carregar_config
# shellcheck disable=SC2153
[[ "$PROJETO" != default ]] || falhar 'Por segurança, destroy.sh não opera no projeto default.'
if [[ -n "$CONFIRM_VOLUMES" && "$APAGAR_VOLUMES" != true ]]; then
  falhar '--confirm-volumes só pode ser usado junto com --volumes.'
fi
VOLUME_TOKEN="APAGAR-VOLUMES:${PROJETO}/${ENV}"
if [[ -n "$CONFIRM_VOLUMES" && "$CONFIRM_VOLUMES" != "$PROJETO/$ENV" ]]; then
  falhar "Token de volumes incorreto; esperado: $PROJETO/$ENV. Nada foi removido."
fi
if "$APAGAR_VOLUMES" && ! "$DRY_RUN" && [[ ! -t 0 ]]; then
  if ! "$SIM" || [[ "$CONFIRM_VOLUMES" != "$PROJETO/$ENV" ]]; then
    falhar "Modo não interativo exige --yes e --confirm-volumes $PROJETO/$ENV com --volumes. Nada foi removido."
  fi
fi

# shellcheck disable=SC2153
printf 'Projeto: %s | Ambiente: %s | Pool: %s\n' "$PROJETO" "$ENV" "$POOL"
printf 'Instâncias alvo: %s\n' "${INSTANCIAS[*]}"
printf 'Raiz/snapshots: %s\n' 'serão removidos das instâncias alvo (se existirem)'
if "$APAGAR_VOLUMES"; then
  printf 'Volumes exatos: APAGAR %s\n' "${VOLUMES[*]}"
  printf 'Confirmação EXTRA exigida: %s\n' "$VOLUME_TOKEN"
else
  printf 'Volumes exatos: PRESERVAR %s\n' "${VOLUMES[*]}"
fi
printf 'TLS local: PRESERVAR %s/conf/tls/%s (certificados e chaves não são tocados).\n' "$RAIZ" "$ENV"
printf 'Redes, profiles, pool e projeto: PRESERVAR.\n'
if "$DRY_RUN"; then
  printf 'PLANO apenas. Nenhum comando LXD foi executado.\n'
  exit 0
fi

# Em modo interativo, --yes continua sendo apenas a confirmação de raízes.
checar_lxd
PROJETOS="$(lx_global project list --format=json)"
if ! python3 -c 'import json,sys; sys.exit(0 if any(p["name"]==sys.argv[1] for p in json.loads(sys.argv[2])) else 1)' "$PROJETO" "$PROJETOS"; then
  log 'Projeto ausente; nada a remover.'
  exit 0
fi
validar_projeto
EXISTENTES="$(listar_instancias)"
VOLUMES_JSON='[]'
if "$APAGAR_VOLUMES"; then
  POOLS="$(lx_global storage list --format=json)"
  if python3 -c 'import json,sys; sys.exit(0 if any(p["name"]==sys.argv[1] for p in json.loads(sys.argv[2])) else 1)' "$POOL" "$POOLS"; then
    VOLUMES_JSON="$(lx storage volume list "$POOL" --format=json)"
  fi
  # Se um volume estiver em uso por outro ambiente/recurso, aborta ANTES de remover instâncias.
  python3 - "$VOLUMES_JSON" "$PROJETO" "$PREFIXO" <<'PY'
import json
import sys
import urllib.parse

volumes, project, prefix = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
names = {prefix + 'vol-db', prefix + 'vol-uploads'}
allowed = {prefix + name for name in ('proxy', 'app', 'db')}
for volume in volumes:
    if volume.get('type') != 'custom' or volume.get('name') not in names:
        continue
    for ref in volume.get('used_by', []):
        parsed = urllib.parse.urlparse(ref)
        parts = parsed.path.strip('/').split('/')
        owner = urllib.parse.parse_qs(parsed.query).get('project', ['default'])[0]
        if len(parts) != 3 or parts[:2] != ['1.0', 'instances'] or parts[2] not in allowed or owner != project:
            raise SystemExit(
                'Volume ' + volume['name'] + ' em uso por outro recurso: ' +
                ref + '; nada foi removido.'
            )
PY
fi

if ! "$SIM"; then
  confirmar "Remover as três instâncias de $ENV (inclui discos raiz e snapshots). Faça backup antes." "$PROJETO/$ENV"
fi
if "$APAGAR_VOLUMES" && [[ -t 0 ]]; then
  # Esta é uma confirmação diferente de --yes e nunca é implícita.
  confirmar 'ATENÇÃO EXTRA: isto apagará permanentemente banco e uploads.' "$VOLUME_TOKEN"
fi

instancia_presente() {
  local procurada="$1" nome
  while IFS= read -r nome; do
    [[ "$nome" == "$procurada" ]] && return 0
  done <<< "$EXISTENTES"
  return 1
}
for nome in "${INSTANCIAS[@]}"; do
  if instancia_presente "$nome"; then
    log "Removendo $nome (disco raiz e snapshots)"
    # Não oculta erros: se falhar, interrompe ANTES da etapa de volumes.
    lx delete --force "$nome"
  else
    log "$nome já está ausente"
  fi
done
if "$APAGAR_VOLUMES"; then
  for volume in "${VOLUMES[@]}"; do
    if python3 -c 'import json,sys; sys.exit(0 if any(v.get("name")==sys.argv[1] and v.get("type")=="custom" for v in json.loads(sys.argv[2])) else 1)' "$volume" "$VOLUMES_JSON"; then
      log "Apagando volume exato $volume"
      lx storage volume delete "$POOL" "$volume"
    else
      log "$volume já está ausente"
    fi
  done
  log 'Instâncias e volumes alvo removidos; demais recursos e TLS local preservados.'
else
  log 'Instâncias removidas. Volumes do banco e uploads foram mantidos.'
fi
