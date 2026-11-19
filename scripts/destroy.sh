#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
ajuda() {
  cat <<'TXT'
Uso: ENV=prod ./scripts/destroy.sh [--dry-run] [--volumes] [--yes]
     ENV=dev  ./scripts/destroy.sh
--env prod|dev  Seleciona o ambiente (padrão ENV=prod).
--dry-run       Mostra nomes exatos, sem consultar ou alterar LXD.
--volumes       Também apaga vol-db e vol-uploads DESTE ambiente. Perda de dados!
--yes           Confirma explicitamente a operação sem pergunta interativa.
Sem --volumes, os dados do banco e uploads são mantidos. Discos raiz e snapshots
DAS INSTÂNCIAS são removidos. Não remove redes, profiles, pool nem projeto.
TXT
}
APAGAR_VOLUMES=false; SIM=false; DRY_RUN=false
while (($#)); do
  case "$1" in
    --env) [[ $# -ge 2 ]] || falhar 'Falta o valor de --env.'; ENV="$2"; shift 2 ;;
    --volumes) APAGAR_VOLUMES=true; shift ;;
    --yes) SIM=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) ajuda; exit 0 ;;
    *) falhar "Parâmetro desconhecido: $1" ;;
  esac
done
carregar_config
[[ "$PROJETO" != default ]] || falhar 'Por segurança, destroy.sh não opera no projeto default.'
printf 'Projeto: %s | Ambiente: %s | Pool: %s\n' "$PROJETO" "$ENV" "$POOL"
printf 'Instâncias alvo: %s\n' "${INSTANCIAS[*]}"
if "$APAGAR_VOLUMES"; then
  printf 'PERDA PERMANENTE: apagar também %s\n' "${VOLUMES[*]}"
else
  printf 'Volumes preservados: %s\n' "${VOLUMES[*]}"
fi
if "$DRY_RUN"; then printf 'PLANO apenas. Nenhum comando LXD foi executado.\n'; exit 0; fi
checar_lxd
PROJETOS="$(lx_global project list --format=json)"
if ! python3 -c 'import json,sys; sys.exit(0 if any(p["name"]==sys.argv[1] for p in json.loads(sys.argv[2])) else 1)' "$PROJETO" "$PROJETOS"; then
  log 'Projeto ausente; nada a remover.'; exit 0
fi
validar_projeto
EXISTENTES="$(listar_instancias)"
VOLUMES_JSON='[]'
if "$APAGAR_VOLUMES"; then
  POOLS="$(lx_global storage list --format=json)"
  if python3 -c 'import json,sys; sys.exit(0 if any(p["name"]==sys.argv[1] for p in json.loads(sys.argv[2])) else 1)' "$POOL" "$POOLS"; then
    VOLUMES_JSON="$(lx storage volume list "$POOL" --format=json)"
  fi
  # Se um volume estiver em uso por outro ambiente, aborta ANTES de remover instâncias.
  python3 - "$VOLUMES_JSON" "$PROJETO" "$PREFIXO" <<'PY'
import json,sys,urllib.parse
volumes,project,prefix=json.loads(sys.argv[1]),sys.argv[2],sys.argv[3]
names={prefix+'vol-db',prefix+'vol-uploads'}
allowed={prefix+n for n in ('proxy','app','db')}
for v in volumes:
    if v.get('type')!='custom' or v['name'] not in names: continue
    for ref in v.get('used_by',[]):
        u=urllib.parse.urlparse(ref); parts=u.path.strip('/').split('/')
        query=urllib.parse.parse_qs(u.query)
        owner=query.get('project',['default'])[0]
        if len(parts)!=3 or parts[:2]!=['1.0','instances'] or parts[2] not in allowed or owner!=project:
            raise SystemExit('Volume '+v['name']+' em uso por outro recurso: '+ref+'; nada foi removido.')
PY
fi
if ! "$SIM"; then
  MENSAGEM="Remover as três instâncias de $ENV (inclui discos raiz e snapshots). Faça backup antes."
  "$APAGAR_VOLUMES" && MENSAGEM+=' Também APAGAR os dados do MariaDB e as imagens enviadas.'
  confirmar "$MENSAGEM" "$PROJETO/$ENV"
fi
for nome in "${INSTANCIAS[@]}"; do
  if grep -Fxq -- "$nome" <<< "$EXISTENTES"; then
    log "Removendo $nome"
    # Não oculta erros: se falhar, interrompe ANTES da etapa de volumes.
    lx delete --force "$nome"
  else log "$nome já está ausente"; fi
done
if "$APAGAR_VOLUMES"; then
  for volume in "${VOLUMES[@]}"; do
    if python3 -c 'import json,sys; sys.exit(0 if any(v["name"]==sys.argv[1] and v.get("type")=="custom" for v in json.loads(sys.argv[2])) else 1)' "$volume" "$VOLUMES_JSON"; then
      log "Apagando volume $volume"
      lx storage volume delete "$POOL" "$volume"
    else log "$volume já está ausente"; fi
  done
  log 'Instâncias e volumes alvo removidos; demais recursos preservados.'
else
  log 'Instâncias removidas. Volumes do banco e uploads foram mantidos.'
fi
