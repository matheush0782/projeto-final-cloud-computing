#!/usr/bin/env bash
# ==============================================================================
# Fase 4 · Isolamento de Redes e Exposição Controlada
# Roteiro: Nuvem privada com LXD/Incus (Trilha A - WordPress)
#
# Este script implementa as seguintes metas:
# 1. Provar que o banco não é acessível de fora (apenas proxy publicado)
# 2. Impedir comunicação direta entre as redes PROD (10.10.10.0/24) e DEV (10.10.20.0/24)
# 3. Aplicar ACLs de rede (acl-prod e acl-dev) de forma idempotente
# 4. Manter tráfego padrão liberado (default allow) para internet (NAT) e gateway
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"
carregar_config
exigir_comandos lxc python3

checar_lxd

ajuda() {
  cat <<'TXT'
Uso: ./scripts/fase4-acls.sh [OPÇÕES]

Opções:
  --apply       Aplica as ACLs de isolamento e regras de rede (padrão se omitido).
  --status      Exibe o estado atual das ACLs e das redes net-prod e net-dev.
  --dry-run     Simula as ações que seriam executadas sem alterar recursos.
  --test        Executa o teste de conectividade (DEV -> PROD) e validação do serviço.
  --rollback    Desfaz a aplicação das ACLs e restaura as redes ao estado padrão.
  --yes         Confirmação automática para operações com impacto (ex: rollback).
  -h, --help    Exibe esta mensagem de ajuda.

Regras aplicadas:
  - acl-prod: Descarta ingress de 10.10.20.0/24 e egress para 10.10.20.0/24
  - acl-dev:  Descarta ingress de 10.10.10.0/24 e egress para 10.10.10.0/24
  - net-prod: security.acls=acl-prod, default ingress/egress=allow
  - net-dev:  security.acls=acl-dev,  default ingress/egress=allow
TXT
}

SIM=false

# Detecta se as redes pertencem ao projeto default ou ao projeto da equipe
detectar_projeto_rede() {
  if lx_global network show net-prod >/dev/null 2>&1; then
    echo "default"
  elif command lxc --project="$PROJETO" network show net-prod >/dev/null 2>&1; then
    echo "$PROJETO"
  else
    echo "default"
  fi
}

PROJETO_REDE="$(detectar_projeto_rede)"
lx_net() { command lxc --project="$PROJETO_REDE" network "$@"; }
lx_acl() { command lxc --project="$PROJETO_REDE" network acl "$@"; }

# Verifica se uma ACL existe
existe_acl() {
  local acl="$1"
  lx_acl show "$acl" >/dev/null 2>&1
}

# Verifica se uma instância existe no projeto
existe_instancia() {
  local nome="$1"
  lx info "$nome" >/dev/null 2>&1
}

# Verifica se uma regra específica já está cadastrada na ACL
tem_regra_acl() {
  local acl="$1" direcao="$2" alvo="$3"
  lx_acl show "$acl" 2>/dev/null | python3 -c '
import sys, yaml
direcao = sys.argv[1]
alvo = sys.argv[2]
try:
    dados = yaml.safe_load(sys.stdin)
    regras = dados.get("rules", []) if isinstance(dados, dict) else []
    for r in regras:
        if r.get("direction") == direcao:
            if direcao == "ingress" and r.get("source") == alvo and r.get("action") == "drop":
                sys.exit(0)
            if direcao == "egress" and r.get("destination") == alvo and r.get("action") == "drop":
                sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
' "$direcao" "$alvo"
}

# Obtém valor de configuração de uma rede de forma segura
obter_config_rede() {
  local rede="$1" chave="$2"
  lx_net get "$rede" "$chave" 2>/dev/null || echo ""
}

# Consulta se a ACL está em uso por outras entidades além da rede esperada
obter_uso_acl() {
  local acl="$1"
  lx_acl show "$acl" 2>/dev/null | python3 -c '
import sys, yaml
try:
    dados = yaml.safe_load(sys.stdin)
    usado = dados.get("used_by", []) if isinstance(dados, dict) else []
    for u in usado:
        print(u)
except Exception:
    pass
'
}

# ==============================================================================
# MODO: STATUS
# ==============================================================================
mostrar_status() {
  printf '=== [Fase 4] Status de Isolamento e ACLs de Rede ===\n\n'
  printf 'Projeto do LXD: %s | Projeto de Redes: %s\n\n' "$PROJETO" "$PROJETO_REDE"

  printf '[1] ACLs cadastradas no LXD:\n'
  lx_acl list || true
  printf '\n'

  printf '[2] Detalhes de acl-prod:\n'
  if existe_acl acl-prod; then
    lx_acl show acl-prod
  else
    printf '  (acl-prod nao criada)\n'
  fi
  printf '\n'

  printf '[3] Detalhes de acl-dev:\n'
  if existe_acl acl-dev; then
    lx_acl show acl-dev
  else
    printf '  (acl-dev nao criada)\n'
  fi
  printf '\n'

  printf '[4] Associacao e politicas padrao nas redes:\n'
  for rede in net-prod net-dev; do
    printf '  Rede: %s\n' "$rede"
    printf '    security.acls:                        %s\n' "$(obter_config_rede "$rede" security.acls)"
    printf '    security.acls.default.ingress.action: %s\n' "$(obter_config_rede "$rede" security.acls.default.ingress.action)"
    printf '    security.acls.default.egress.action:  %s\n' "$(obter_config_rede "$rede" security.acls.default.egress.action)"
  done
  printf '\n'

  printf '[5] Dispositivos proxy expostos nas instancias de PROD:\n'
  for inst in proxy app db; do
    printf '  Instancia: %s\n' "$inst"
    lx config device list "$inst" 2>/dev/null | while read -r dev; do
      tipo="$(lx config device get "$inst" "$dev" type 2>/dev/null || true)"
      if [[ "$tipo" == "proxy" ]]; then
        listen="$(lx config device get "$inst" "$dev" listen 2>/dev/null || true)"
        connect="$(lx config device get "$inst" "$dev" connect 2>/dev/null || true)"
        printf '    - %s (proxy: listen=%s -> connect=%s)\n' "$dev" "$listen" "$connect"
      fi
    done
  done
  printf '\n'
}

# ==============================================================================
# MODO: DRY-RUN (SIMULAÇÃO)
# ==============================================================================
executar_dry_run() {
  printf '=== [Fase 4] Simulacao de Aplicacao (dry-run) ===\n\n'
  printf 'Nenhuma alteracao sera realizada no ambiente.\n\n'

  # acl-prod
  if existe_acl acl-prod; then
    printf '[OK] acl-prod ja existe no LXD.\n'
  else
    printf '[CRIAR] lxc network acl create acl-prod (projeto: %s)\n' "$PROJETO_REDE"
  fi
  if tem_regra_acl acl-prod ingress 10.10.20.0/24; then
    printf '[OK] acl-prod ja contem regra ingress drop source=10.10.20.0/24.\n'
  else
    printf '[ADICIONAR] lxc network acl rule add acl-prod ingress action=drop source=10.10.20.0/24\n'
  fi
  if tem_regra_acl acl-prod egress 10.10.20.0/24; then
    printf '[OK] acl-prod ja contem regra egress drop destination=10.10.20.0/24.\n'
  else
    printf '[ADICIONAR] lxc network acl rule add acl-prod egress action=drop destination=10.10.20.0/24\n'
  fi

  # net-prod
  if [[ "$(obter_config_rede net-prod security.acls)" == "acl-prod" ]]; then
    printf '[OK] net-prod ja esta associada a acl-prod.\n'
  else
    printf '[CONFIGURAR] lxc network set net-prod security.acls=acl-prod\n'
  fi
  if [[ "$(obter_config_rede net-prod security.acls.default.ingress.action)" == "allow" ]]; then
    printf '[OK] net-prod ja possui security.acls.default.ingress.action=allow.\n'
  else
    printf '[CONFIGURAR] lxc network set net-prod security.acls.default.ingress.action=allow\n'
  fi
  if [[ "$(obter_config_rede net-prod security.acls.default.egress.action)" == "allow" ]]; then
    printf '[OK] net-prod ja possui security.acls.default.egress.action=allow.\n'
  else
    printf '[CONFIGURAR] lxc network set net-prod security.acls.default.egress.action=allow\n'
  fi

  # acl-dev
  if existe_acl acl-dev; then
    printf '[OK] acl-dev ja existe no LXD.\n'
  else
    printf '[CRIAR] lxc network acl create acl-dev (projeto: %s)\n' "$PROJETO_REDE"
  fi
  if tem_regra_acl acl-dev ingress 10.10.10.0/24; then
    printf '[OK] acl-dev ja contem regra ingress drop source=10.10.10.0/24.\n'
  else
    printf '[ADICIONAR] lxc network acl rule add acl-dev ingress action=drop source=10.10.10.0/24\n'
  fi
  if tem_regra_acl acl-dev egress 10.10.10.0/24; then
    printf '[OK] acl-dev ja contem regra egress drop destination=10.10.10.0/24.\n'
  else
    printf '[ADICIONAR] lxc network acl rule add acl-dev egress action=drop destination=10.10.10.0/24\n'
  fi

  # net-dev
  if [[ "$(obter_config_rede net-dev security.acls)" == "acl-dev" ]]; then
    printf '[OK] net-dev ja esta associada a acl-dev.\n'
  else
    printf '[CONFIGURAR] lxc network set net-dev security.acls=acl-dev\n'
  fi
  if [[ "$(obter_config_rede net-dev security.acls.default.ingress.action)" == "allow" ]]; then
    printf '[OK] net-dev ja possui security.acls.default.ingress.action=allow.\n'
  else
    printf '[CONFIGURAR] lxc network set net-dev security.acls.default.ingress.action=allow\n'
  fi
  if [[ "$(obter_config_rede net-dev security.acls.default.egress.action)" == "allow" ]]; then
    printf '[OK] net-dev ja possui security.acls.default.egress.action=allow.\n'
  else
    printf '[CONFIGURAR] lxc network set net-dev security.acls.default.egress.action=allow\n'
  fi

  printf '\nSimulacao concluida com sucesso.\n'
}

# ==============================================================================
# MODO: APLICAR (APPLY)
# ==============================================================================
aplicar_acls() {
  log "Iniciando aplicacao das ACLs de isolamento (Fase 4)..."

  # 1. Configurar acl-prod
  if ! existe_acl acl-prod; then
    log "Criando ACL acl-prod..."
    lx_acl create acl-prod
  else
    log "ACL acl-prod ja existe."
  fi

  if ! tem_regra_acl acl-prod ingress 10.10.20.0/24; then
    log "Adicionando regra ingress drop em acl-prod (origem 10.10.20.0/24)..."
    lx_acl rule add acl-prod ingress action=drop source=10.10.20.0/24
  else
    log "Regra ingress de acl-prod ja presente."
  fi

  if ! tem_regra_acl acl-prod egress 10.10.20.0/24; then
    log "Adicionando regra egress drop em acl-prod (destino 10.10.20.0/24)..."
    lx_acl rule add acl-prod egress action=drop destination=10.10.20.0/24
  else
    log "Regra egress de acl-prod ja presente."
  fi

  # 2. Associar acl-prod a net-prod
  log "Configurando net-prod com acl-prod e politicas padrao allow..."
  if ! lx_net set net-prod security.acls=acl-prod 2>/dev/null; then
    falhar "Falha ao definir security.acls em net-prod. Verifique se o driver de firewall (ex: nftables/ovs) esta ativo no host."
  fi
  lx_net set net-prod security.acls.default.ingress.action=allow
  lx_net set net-prod security.acls.default.egress.action=allow

  # 3. Configurar acl-dev
  if ! existe_acl acl-dev; then
    log "Criando ACL acl-dev..."
    lx_acl create acl-dev
  else
    log "ACL acl-dev ja existe."
  fi

  if ! tem_regra_acl acl-dev ingress 10.10.10.0/24; then
    log "Adicionando regra ingress drop em acl-dev (origem 10.10.10.0/24)..."
    lx_acl rule add acl-dev ingress action=drop source=10.10.10.0/24
  else
    log "Regra ingress de acl-dev ja presente."
  fi

  if ! tem_regra_acl acl-dev egress 10.10.10.0/24; then
    log "Adicionando regra egress drop em acl-dev (destino 10.10.10.0/24)..."
    lx_acl rule add acl-dev egress action=drop destination=10.10.10.0/24
  else
    log "Regra egress de acl-dev ja presente."
  fi

  # 4. Associar acl-dev a net-dev
  log "Configurando net-dev com acl-dev e politicas padrao allow..."
  if ! lx_net set net-dev security.acls=acl-dev 2>/dev/null; then
    falhar "Falha ao definir security.acls em net-dev. Verifique o driver de firewall no host."
  fi
  lx_net set net-dev security.acls.default.ingress.action=allow
  lx_net set net-dev security.acls.default.egress.action=allow

  log "ACLs aplicadas com sucesso! Isolamento entre PROD e DEV ativo."
}

# ==============================================================================
# MODO: ROLLBACK (DESFAZER)
# ==============================================================================
desfazer_acls() {
  log "Iniciando verificacao para rollback seguro das ACLs da Fase 4..."

  if ! "$SIM"; then
    confirmar "Deseja remover as ACLs da Fase 4 e reverter net-prod e net-dev ao estado sem ACL?" "reverter-acls"
  fi

  # 1. Remover associacao de net-prod SOMENTE se apontar para acl-prod
  local acl_atual_prod
  acl_atual_prod="$(obter_config_rede net-prod security.acls)"
  if [[ "$acl_atual_prod" == "acl-prod" ]]; then
    log "Desvinculando acl-prod de net-prod..."
    lx_net unset net-prod security.acls || falhar "Falha ao desvincular security.acls de net-prod."
    lx_net unset net-prod security.acls.default.ingress.action || true
    lx_net unset net-prod security.acls.default.egress.action || true
  elif [[ -n "$acl_atual_prod" ]]; then
    log "Aviso: net-prod possui ACL '$acl_atual_prod' (diferente de acl-prod); mantida intacta."
  else
    log "net-prod ja nao possui ACL vinculada."
  fi

  # 2. Remover associacao de net-dev SOMENTE se apontar para acl-dev
  local acl_atual_dev
  acl_atual_dev="$(obter_config_rede net-dev security.acls)"
  if [[ "$acl_atual_dev" == "acl-dev" ]]; then
    log "Desvinculando acl-dev de net-dev..."
    lx_net unset net-dev security.acls || falhar "Falha ao desvincular security.acls de net-dev."
    lx_net unset net-dev security.acls.default.ingress.action || true
    lx_net unset net-dev security.acls.default.egress.action || true
  elif [[ -n "$acl_atual_dev" ]]; then
    log "Aviso: net-dev possui ACL '$acl_atual_dev' (diferente de acl-dev); mantida intacta."
  else
    log "net-dev ja nao possui ACL vinculada."
  fi

  # 3. Remover acl-prod SOMENTE se nao estiver mais em uso
  if existe_acl acl-prod; then
    local uso_prod
    uso_prod="$(obter_uso_acl acl-prod)"
    if [[ -z "$uso_prod" ]]; then
      log "Excluindo ACL acl-prod (nao utilizada)..."
      lx_acl delete acl-prod || falhar "Falha ao excluir acl-prod."
    else
      log "Aviso: acl-prod ainda esta associada a outros recursos ($uso_prod); exclusao ignorada por seguranca."
    fi
  else
    log "acl-prod nao existe; nenhuma acao necessaria."
  fi

  # 4. Remover acl-dev SOMENTE se nao estiver mais em uso
  if existe_acl acl-dev; then
    local uso_dev
    uso_dev="$(obter_uso_acl acl-dev)"
    if [[ -z "$uso_dev" ]]; then
      log "Excluindo ACL acl-dev (nao utilizada)..."
      lx_acl delete acl-dev || falhar "Falha ao excluir acl-dev."
    else
      log "Aviso: acl-dev ainda esta associada a outros recursos ($uso_dev); exclusao ignorada por seguranca."
    fi
  else
    log "acl-dev nao existe; nenhuma acao necessaria."
  fi

  log "Rollback da Fase 4 concluido com sucesso."
}

# ==============================================================================
# MODO: TESTE E VALIDAÇÃO COMPLETA
# ==============================================================================
executar_testes() {
  exigir_comandos timeout curl
  log "Iniciando validacao de isolamento e disponibilidade (Fase 4)..."

  # Gerar nome exclusivo para cada execucao de teste (evita conflitos e exclusao acidental)
  local id_unico nome_teste
  id_unico="$(date +%s)-$RANDOM"
  nome_teste="teste-fase4-${id_unico}"
  local criou_instancia=false

  # Garante protecao contra instancias preexistentes: verifica antes de iniciar
  if existe_instancia "$nome_teste"; then
    falhar "A instancia de teste $nome_teste ja existe no projeto $PROJETO. Abortando para proteger recursos existentes."
  fi

  # Funcao de limpeza estrita: APENAS remove o container criado por esta execucao
  remover_teste_dev() {
    if "$criou_instancia"; then
      log "Limpando instancia temporaria criada nesta execucao ($nome_teste)..."
      lx delete -f "$nome_teste" >/dev/null 2>&1 || log "Aviso: falha ao remover automaticamente $nome_teste."
      criou_instancia=false
    fi
  }
  trap remover_teste_dev EXIT

  # 1. Criar instancia temporaria exclusiva na rede net-dev
  log "Inicializando container de teste exclusivo '$nome_teste' na rede net-dev..."
  lx init "$IMAGEM" "$nome_teste" -p perfil-base
  criou_instancia=true

  lx config device override "$nome_teste" eth0 network=net-dev
  lx start "$nome_teste"

  log "Aguardando inicializacao do container $nome_teste..."
  lx exec "$nome_teste" -- cloud-init status --wait >/dev/null 2>&1 || sleep 5

  local -a falhas=()

  # 2. Testar acesso de DEV ao banco de dados de PROD (10.10.10.12:3306)
  log "Testando conectividade: $nome_teste (DEV) -> db (10.10.10.12:3306)..."
  local resultado_dev
  resultado_dev="$(lx exec "$nome_teste" -- bash -c 'timeout 3 bash -c "echo > /dev/tcp/10.10.10.12/3306" 2>/dev/null && echo ALCANCOU || echo BLOQUEADO')"

  printf '\n============================================================\n'
  printf 'RESULTADO DO ISOLAMENTO DEV -> BANCO PROD: %s\n' "$resultado_dev"
  printf '============================================================\n\n'

  if [[ "$resultado_dev" != "BLOQUEADO" ]]; then
    falhas+=("Isolamento violado: comunicacao DEV -> banco PROD resultou em '$resultado_dev' (esperado: BLOQUEADO).")
  else
    log "[OK] Isolamento DEV -> Banco PROD validado com sucesso (BLOQUEADO)."
  fi

  # 3. Validar acesso a internet da aplicacao (default allow ativo)
  log "Validando saida para a internet a partir de 'app' (https://deb.debian.org)..."
  local status_internet
  status_internet="$(lx exec app -- curl -sI --max-time 10 https://deb.debian.org 2>/dev/null | head -1 || echo "FALHA")"
  printf 'Saida da aplicacao para internet: %s\n' "$status_internet"

  if [[ "$status_internet" =~ ^HTTP/[0-9.]+[[:space:]]+(200|301|302) ]]; then
    log "[OK] Conectividade de saida para a internet validada."
  else
    falhas+=("Conectividade de saida para internet falhou no container app (resposta: $status_internet).")
  fi

  # 4. Validar servico WordPress via proxy
  log "Validando resposta do servico WordPress na porta 8081..."
  local status_http
  status_http="$(curl -sI --max-time 10 "http://${VM_HOST:-127.0.0.1}:8081" 2>/dev/null | head -1 || echo "FALHA")"
  printf 'Resposta do proxy HTTP (8081):   %s\n' "$status_http"

  if [[ "$status_http" =~ ^HTTP/[0-9.]+[[:space:]]+(200|301|302) ]]; then
    log "[OK] Servico WordPress respondendo adequadamente pelo proxy."
  else
    falhas+=("Proxy reverso HTTP (porta 8081) nao respondeu adequadamente (resposta: $status_http).")
  fi

  # 5. Limpeza do container de teste temporario
  remover_teste_dev
  trap - EXIT

  # Se houver falhas, encerrar com codigo de saida diferente de zero
  if (( ${#falhas[@]} > 0 )); then
    printf '\nERRO: A bateria de testes da Fase 4 falhou com as seguintes inconformidades:\n' >&2
    for item in "${falhas[@]}"; do
      printf '  [FALHA] %s\n' "$item" >&2
    done
    exit 1
  fi

  log "Bateria de testes da Fase 4 concluida com SUCESSO: todas as verificacoes passaram."
}

# ==============================================================================
# DISPATCHER DE COMANDOS
# ==============================================================================
MODO="apply"
while (($#)); do
  case "$1" in
    --status)   MODO="status"; shift ;;
    --dry-run)  MODO="dry-run"; shift ;;
    --apply)    MODO="apply"; shift ;;
    --test)     MODO="test"; shift ;;
    --rollback) MODO="rollback"; shift ;;
    --yes)      SIM=true; shift ;;
    -h|--help)  ajuda; exit 0 ;;
    *)          falhar "Opcao desconhecida: $1. Use --help para instrucoes." ;;
  esac
done

case "$MODO" in
  status)   mostrar_status ;;
  dry-run)  executar_dry_run ;;
  apply)    aplicar_acls ;;
  test)     executar_testes ;;
  rollback) desfazer_acls ;;
esac
