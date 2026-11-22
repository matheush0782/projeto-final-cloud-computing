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
  -h, --help    Exibe esta mensagem de ajuda.

Regras aplicadas:
  - acl-prod: Descarta ingress de 10.10.20.0/24 e egress para 10.10.20.0/24
  - acl-dev:  Descarta ingress de 10.10.10.0/24 e egress para 10.10.10.0/24
  - net-prod: security.acls=acl-prod, default ingress/egress=allow
  - net-dev:  security.acls=acl-dev,  default ingress/egress=allow
TXT
}

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
    printf '    security.acls:                       %s\n' "$(obter_config_rede "$rede" security.acls)"
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
  log "Iniciando rollback das ACLs da Fase 4..."

  # Remover associacao das redes
  for rede in net-prod net-dev; do
    if lx_net show "$rede" >/dev/null 2>&1; then
      log "Removendo politicas de ACL da rede $rede..."
      lx_net unset "$rede" security.acls 2>/dev/null || true
      lx_net unset "$rede" security.acls.default.ingress.action 2>/dev/null || true
      lx_net unset "$rede" security.acls.default.egress.action 2>/dev/null || true
    fi
  done

  # Remover as ACLs
  for acl in acl-prod acl-dev; do
    if existe_acl "$acl"; then
      log "Excluindo ACL $acl..."
      lx_acl delete "$acl" 2>/dev/null || true
    fi
  done

  log "Rollback concluido. As redes net-prod e net-dev voltaram a configuracao original."
}

# ==============================================================================
# MODO: TESTE E VALIDAÇÃO COMPLETA
# ==============================================================================
executar_testes() {
  exigir_comandos timeout curl
  log "Iniciando validacao de isolamento e disponibilidade (Fase 4)..."

  local nome_teste="teste-dev"
  local limpou_teste=false

  remover_teste_dev() {
    if ! $limpou_teste; then
      log "Limpando instancia de teste ($nome_teste)..."
      lx delete -f "$nome_teste" 2>/dev/null || true
      limpou_teste=true
    fi
  }
  trap remover_teste_dev EXIT

  # 1. Criar instancia temporaria na rede net-dev
  log "Inicializando instancia temporaria $nome_teste em net-dev..."
  lx delete -f "$nome_teste" 2>/dev/null || true
  lx init "$IMAGEM" "$nome_teste" -p perfil-base
  lx config device override "$nome_teste" eth0 network=net-dev
  lx start "$nome_teste"

  log "Aguardando boot e rede do $nome_teste..."
  lx exec "$nome_teste" -- cloud-init status --wait >/dev/null 2>&1 || sleep 5

  # 2. Testar acesso de DEV ao banco de dados de PROD (10.10.10.12:3306)
  log "Testando conectividade: $nome_teste (DEV) -> db (10.10.10.12:3306)..."
  local resultado_dev
  resultado_dev="$(lx exec "$nome_teste" -- bash -c 'timeout 3 bash -c "echo > /dev/tcp/10.10.10.12/3306" && echo ALCANCOU || echo BLOQUEADO')"

  printf '\n============================================================\n'
  printf 'RESULTADO DO ISOLAMENTO DEV -> BANCO PROD: %s\n' "$resultado_dev"
  printf '============================================================\n\n'

  if [[ "$resultado_dev" == "BLOQUEADO" ]]; then
    log "[SUCESSO] O banco de dados de producao esta protegido contra a rede DEV!"
  else
    log "[ATENCAO] O banco de producao foi ALCANCADO a partir de DEV. As ACLs precisam ser aplicadas."
  fi

  # 3. Validar acesso a internet da aplicacao (default allow ativo)
  log "Validando acesso de saida da aplicacao para a internet (deb.debian.org)..."
  local status_internet
  status_internet="$(lx exec app -- curl -sI https://deb.debian.org 2>/dev/null | head -1 || echo "FALHA")"
  printf 'Saida da aplicacao para internet: %s\n' "$status_internet"

  # 4. Validar servico WordPress via proxy
  log "Validando resposta do servico WordPress..."
  local status_http
  status_http="$(curl -sI "http://${VM_HOST:-127.0.0.1}:8081" 2>/dev/null | head -1 || echo "FALHA")"
  printf 'Resposta do proxy HTTP (8081):   %s\n' "$status_http"

  remover_teste_dev
  trap - EXIT

  log "Bateria de testes da Fase 4 concluida."
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
