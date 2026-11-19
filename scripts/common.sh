#!/usr/bin/env bash
# Funções compartilhadas; este arquivo deve ser carregado com source.
# Estas variáveis são consumidas pelos scripts que carregam este arquivo.
# shellcheck disable=SC2034

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
falhar() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

carregar_config() {
  ENV="${ENV:-prod}"
  PROJETO="${PROJETO:-final-equipeN}"
  POOL="${POOL:-pool-final}"
  IMAGEM="${IMAGEM:-ubuntu:24.04}"
  [[ "$PROJETO" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || falhar 'Nome de projeto inválido (use letras, números e hífen).'
  [[ "$PROJETO" != default ]] || falhar 'Use um projeto dedicado, não default.'
  [[ "$POOL" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || falhar 'Nome de pool inválido.'
  case "$ENV" in
    prod) PREFIXO=''; REDE='net-prod'; SUBNET='10.10.10'; PORTA_HTTP=8081; PORTA_HTTPS=8444 ;;
    dev) PREFIXO='dev-'; REDE='net-dev'; SUBNET='10.10.20'; PORTA_HTTP=8082; PORTA_HTTPS=8445 ;;
    *) falhar "ENV deve ser prod ou dev, não '$ENV'." ;;
  esac
  INSTANCIAS=("${PREFIXO}proxy" "${PREFIXO}app" "${PREFIXO}db")
  VOLUMES=("${PREFIXO}vol-db" "${PREFIXO}vol-uploads")
  RAIZ="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
}

exigir_comandos() {
  local comando
  for comando in "$@"; do
    command -v "$comando" >/dev/null 2>&1 || falhar "Comando ausente: $comando. Consulte o README."
  done
}

# Não altera o projeto selecionado no terminal nem opera em remotos por acidente.
lx() { command lxc --project="$PROJETO" "$@"; }
lx_global() { command lxc --project=default "$@"; }

checar_lxd() {
  exigir_comandos lxc python3
  local remoto
  remoto="$(command lxc remote get-default)"
  [[ "$remoto" == local ]] || falhar "Remoto atual é '$remoto'. Use lxc remote switch local na VM antes de continuar."
  command lxc info local: >/dev/null
}

# Consultas JSON distinguem objeto inexistente de falha do servidor/permissão.
existe_projeto() {
  lx_global project list --format=json | python3 -c '
import json,sys
sys.exit(0 if any(p["name"]==sys.argv[1] for p in json.load(sys.stdin)) else 1)
' "$PROJETO"
}

listar_instancias() {
  lx list --format=json | python3 -c '
import json,sys
for i in json.load(sys.stdin): print(i["name"])
'
}

validar_projeto() {
  local isolado
  isolado="$(lx_global project get "$PROJETO" features.storage.volumes)"
  [[ "$isolado" == true ]] || falhar 'O projeto precisa de features.storage.volumes=true. Não altere essa opção com dados em uso; confira os volumes e o README.'
  [[ "$(lx_global project get "$PROJETO" features.profiles)" == false ]] || falhar 'Este roteiro usa features.profiles=false (perfis compartilhados). Confira o README antes de migrar um projeto existente.'
  [[ "$(lx_global project get "$PROJETO" features.networks)" != true ]] || falhar 'Este roteiro requer redes bridge compartilhadas: features.networks=false.'
}

confirmar() {
  local mensagem="$1" esperado="$2" resposta
  [[ -t 0 ]] || falhar "Sem terminal interativo. $mensagem Use --yes somente após revisar --dry-run."
  printf '%s\nDigite exatamente %s para confirmar: ' "$mensagem" "$esperado"
  read -r resposta
  [[ "$resposta" == "$esperado" ]] || falhar 'Operação cancelada.'
}
