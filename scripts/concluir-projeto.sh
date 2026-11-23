#!/usr/bin/env bash
# Automação central para validar e concluir o projeto de Cloud Computing
# Uso: ./scripts/concluir-projeto.sh [--check|--plan|--resume|--phase N]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

MODE="${1:---check}"
STAGE_FILE="$ROOT_DIR/.conclusao-stage"

# Contador global de falhas
FAILED=0

fail() {
    echo -e "${RED}[FAIL]${NC} $*" >&2
    FAILED=1
    return 1
}

pass() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

section() {
    echo ""
    echo -e "${BLUE}=== $* ===${NC}"
}

# Função para carregar o stage salvo
load_stage() {
    if [[ -f "$STAGE_FILE" ]]; then
        cat "$STAGE_FILE"
    else
        echo "diagnostico"
    fi
}

# Função para salvar o stage (apenas em modos que não sejam --check)
save_stage() {
    if [[ "$MODE" != "--check" ]]; then
        echo "$1" > "$STAGE_FILE"
    fi
}

# 1. Diagnóstico inicial
diagnostico() {
    section "1. Diagnóstico Inicial"
    
    echo "Verificando repositório..."
    if [[ -d "$ROOT_DIR/.git" ]]; then
        pass "Repositório git encontrado"
    else
        fail "Repositório git não encontrado"
        return 1
    fi
    
    echo "Verificando estrutura de diretórios..."
    local dirs=("scripts" "profiles" "networks" "conf" "docs" "tests" ".github")
    for dir in "${dirs[@]}"; do
        if [[ -d "$ROOT_DIR/$dir" ]]; then
            pass "Diretório: $dir"
        else
            warn "Diretório ausente: $dir"
        fi
    done
    
    save_stage "diagnostico-concluido"
    return 0
}

# 2. Verificar scripts da Fase 6
verificar_scripts_fase6() {
    section "2. Verificando Scripts da Fase 6"
    
    local scripts=("01-snapshot.sh" "02-backup.sh" "03-restore.sh" "04-limpeza.sh" "common.sh")
    local missing=0
    
    for script in "${scripts[@]}"; do
        if [[ -f "$ROOT_DIR/scripts/$script" ]]; then
            pass "scripts/$script"
        else
            fail "scripts/$script"
            missing=1
        fi
    done
    
    if [[ $missing -eq 1 ]]; then
        return 1
    fi
    
    save_stage "scripts-verificados"
    return 0
}

# 3. Verificar sintaxe Bash
verificar_sintaxe_bash() {
    section "3. Verificando Sintaxe Bash"
    
    local scripts=("01-snapshot.sh" "02-backup.sh" "03-restore.sh" "04-limpeza.sh" "common.sh" "deploy.sh" "destroy.sh" "monitor.sh" "fase5-tls.sh" "fase5-acesso.sh" "registrar-evidencias.sh" "test-limits.sh")
    local failed=0
    
    for script in "${scripts[@]}"; do
        if [[ -f "$ROOT_DIR/scripts/$script" ]]; then
            if bash -n "$ROOT_DIR/scripts/$script" 2>/dev/null; then
                pass "Sintaxe válida: $script"
            else
                fail "Sintaxe inválida: $script"
                failed=1
            fi
        fi
    done
    
    if [[ $failed -eq 1 ]]; then
        return 1
    fi
    
    save_stage "sintaxe-verificada"
    return 0
}

# 4. Verificar mock_lxc.py
verificar_mock() {
    section "4. Verificando mock_lxc.py"
    
    if [[ ! -f "$ROOT_DIR/tests/mock_lxc.py" ]]; then
        fail "tests/mock_lxc.py não encontrado"
        return 1
    fi
    
    # Verificar implementações essenciais
    local checks=("remote.*get-default" "if a\[:1\] == \[\\\"info\\\"\]" "\\\"local\\\"")
    local missing=0
    
    for check in "${checks[@]}"; do
        if grep -q "$check" "$ROOT_DIR/tests/mock_lxc.py"; then
            pass "Mock implementa: $check"
        else
            fail "Mock não implementa: $check"
            missing=1
        fi
    done
    
    if [[ $missing -eq 1 ]]; then
        return 1
    fi
    
    save_stage "mock-verificado"
    return 0
}

# 5. Verificar workflow GitHub Actions
verificar_workflow() {
    section "5. Verificando Workflow GitHub Actions"
    
    if [[ ! -f "$ROOT_DIR/.github/workflows/fase-6.yml" ]]; then
        fail ".github/workflows/fase-6.yml não encontrado"
        return 1
    fi
    
    pass ".github/workflows/fase-6.yml"
    
    # Verificar caminhos do workflow
    local paths=("scripts/01-snapshot.sh" "scripts/02-backup.sh" "scripts/03-restore.sh" 
                 "scripts/04-limpeza.sh" "docs/fase-6/README.md" "tests/test_fase6.sh")
    
    for path in "${paths[@]}"; do
        if [[ -f "$ROOT_DIR/$path" ]]; then
            pass "Caminho existe: $path"
        else
            fail "Caminho ausente: $path"
        fi
    done
    
    save_stage "workflow-verificado"
    return 0
}

# 6. Verificar documentação
verificar_documentacao() {
    section "6. Verificando Documentação"
    
    if [[ -f "$ROOT_DIR/docs/fase-6/README.md" ]]; then
        pass "docs/fase-6/README.md"
    else
        fail "docs/fase-6/README.md"
        return 1
    fi
    
    save_stage "documentacao-verificada"
    return 0
}

# 7. Verificar ausência de exemplos destrutivos
verificar_exemplos_destrutivos() {
    section "7. Verificando Ausência de Exemplos Destrutivos"
    
    local scripts=("02-backup.sh" "03-restore.sh" "04-limpeza.sh")
    local failed=0
    
    for script in "${scripts[@]}"; do
        if [[ -f "$ROOT_DIR/scripts/$script" ]]; then
            local last_lines
            last_lines=$(tail -5 "$ROOT_DIR/scripts/$script")
            
            if echo "$last_lines" | grep -q '^\./scripts/'; then
                fail "scripts/$script ainda contém exemplos de comandos no final"
                failed=1
            elif echo "$last_lines" | grep -q '^lxc '; then
                fail "scripts/$script ainda contém comandos lxc de exemplo no final"
                failed=1
            else
                pass "scripts/$script não tem exemplos destrutivos no final"
            fi
        fi
    done
    
    if [[ $failed -eq 1 ]]; then
        return 1
    fi
    
    save_stage "exemplos-concluido"
    return 0
}

# 8. Verificar perfis LXD
verificar_perfis() {
    section "8. Verificando Perfis LXD"
    
    if [[ ! -f "$ROOT_DIR/profiles/perfil-base.yaml" ]]; then
        fail "profiles/perfil-base.yaml não encontrado"
        return 1
    fi
    
    local profiles=("perfil-base.yaml" "perfil-proxy.yaml" "perfil-app.yaml" "perfil-db.yaml")
    local missing=0
    
    for profile in "${profiles[@]}"; do
        if [[ -f "$ROOT_DIR/profiles/$profile" ]]; then
            pass "profiles/$profile"
        else
            fail "profiles/$profile"
            missing=1
        fi
    done
    
    if [[ $missing -eq 1 ]]; then
        return 1
    fi
    
    save_stage "perfis-verificados"
    return 0
}

# 9. Verificar redes
verificar_redes() {
    section "9. Verificando Configurações de Rede"
    
    local networks=("networks/prod/net-prod.yaml" "networks/dev/net-dev.yaml")
    local missing=0
    
    for net in "${networks[@]}"; do
        if [[ -f "$ROOT_DIR/$net" ]]; then
            pass "Configuração: $net"
        else
            fail "Configuração ausente: $net"
            missing=1
        fi
    done
    
    if [[ $missing -eq 1 ]]; then
        return 1
    fi
    
    save_stage "redes-verificadas"
    return 0
}

# 10. Verificar configurações
verificar_configs() {
    section "10. Verificando Configurações"
    
    local configs=("conf/nginx-servico.conf" "conf/nginx-servico-https.conf" "conf/instala-wp.sh" "conf/config-mariadb.sh" "conf/atualiza-url-wp.php")
    local missing=0
    
    for config in "${configs[@]}"; do
        if [[ -f "$ROOT_DIR/$config" ]]; then
            pass "Config: $config"
        else
            fail "Config ausente: $config"
            missing=1
        fi
    done
    
    if [[ $missing -eq 1 ]]; then
        return 1
    fi
    
    save_stage "configs-verificadas"
    return 0
}

# Função para executar verificações de uma fase específica
verificar_fase() {
    local fase="$1"
    
    case "$fase" in
        0)
            diagnostico
            ;;
        1)
            verificar_redes
            verificar_configs
            ;;
        2)
            verificar_scripts_fase6
            verificar_perfis
            ;;
        3)
            verificar_mock
            verificar_workflow
            ;;
        4)
            verificar_documentacao
            verificar_exemplos_destrutivos
            ;;
        5)
            verificar_sintaxe_bash
            ;;
        *)
            fail "Fase inválida: $fase (use 0-5)"
            return 1
            ;;
    esac
}

# Principal
main() {
    echo "=========================================="
    echo "Automação de Conclusão do Projeto"
    echo "Modo: $MODE"
    echo "=========================================="
    
    case "$MODE" in
        --check)
            # Modo --check é exclusivamente de leitura, não grava stage
            diagnostico && verificar_scripts_fase6 && verificar_sintaxe_bash && verificar_mock && verificar_workflow && verificar_documentacao && verificar_exemplos_destrutivos && verificar_perfis && verificar_redes && verificar_configs
            ;;
        --plan)
            echo "Plano de validação:"
            echo "1. Diagnóstico inicial (repositório, diretórios)"
            echo "2. Verificar scripts da Fase 6 (01-snapshot.sh a 04-limpeza.sh, common.sh)"
            echo "3. Verificar sintaxe Bash (todos os scripts em scripts/)"
            echo "4. Verificar mock_lxc.py (implementações essenciais)"
            echo "5. Verificar workflow GitHub Actions (.github/workflows/fase-6.yml)"
            echo "6. Verificar documentação (docs/fase-6/README.md)"
            echo "7. Verificar ausência de exemplos destrutivos"
            echo "8. Verificar perfis LXD (perfil-base.yaml, perfil-proxy.yaml, perfil-app.yaml, perfil-db.yaml)"
            echo "9. Verificar configurações de rede (networks/prod/net-prod.yaml, networks/dev/net-dev.yaml)"
            echo "10. Verificar configurações (conf/*.conf, conf/*.sh, conf/*.php)"
            ;;
        --resume)
            local stage
            stage=$(load_stage)
            echo "Retomando a partir do stage: $stage"
            case "$stage" in
                "diagnostico-concluido")
                    verificar_scripts_fase6 && verificar_sintaxe_bash && verificar_mock && verificar_workflow && verificar_documentacao && verificar_exemplos_destrutivos && verificar_perfis && verificar_redes && verificar_configs
                    ;;
                "scripts-verificados")
                    verificar_sintaxe_bash && verificar_mock && verificar_workflow && verificar_documentacao && verificar_exemplos_destrutivos && verificar_perfis && verificar_redes && verificar_configs
                    ;;
                "sintaxe-verificada")
                    verificar_mock && verificar_workflow && verificar_documentacao && verificar_exemplos_destrutivos && verificar_perfis && verificar_redes && verificar_configs
                    ;;
                "mock-verificado")
                    verificar_workflow && verificar_documentacao && verificar_exemplos_destrutivos && verificar_perfis && verificar_redes && verificar_configs
                    ;;
                "workflow-verificado")
                    verificar_documentacao && verificar_exemplos_destrutivos && verificar_perfis && verificar_redes && verificar_configs
                    ;;
                "documentacao-verificada")
                    verificar_exemplos_destrutivos && verificar_perfis && verificar_redes && verificar_configs
                    ;;
                "exemplos-concluido")
                    verificar_perfis && verificar_redes && verificar_configs
                    ;;
                "perfis-verificados")
                    verificar_redes && verificar_configs
                    ;;
                "redes-verificadas")
                    verificar_configs
                    ;;
                "configs-verificadas")
                    echo "Todas as verificações já concluídas."
                    ;;
                *)
                    echo "Stage desconhecido ou inválido: $stage. Executando verificação completa."
                    diagnostico && verificar_scripts_fase6 && verificar_sintaxe_bash && verificar_mock && verificar_workflow && verificar_documentacao && verificar_exemplos_destrutivos && verificar_perfis && verificar_redes && verificar_configs
                    ;;
            esac
            ;;
        --phase)
            local phase_num="${2:-}"
            if [[ -z "$phase_num" ]]; then
                fail "Número da fase não informado. Uso: $0 --phase N (0-5)"
                exit 1
            fi
            verificar_fase "$phase_num"
            ;;
        --apply)
            fail "Modo --apply não implementado: operações de infraestrutura requerem validação manual e autorização específica. Use --check, --plan, --resume ou --phase."
            exit 1
            ;;
        *)
            fail "Modo desconhecido: $MODE"
            echo "Uso: $0 [--check|--plan|--resume|--phase N]"
            echo "  --check    : Validação completa (somente leitura)"
            echo "  --plan     : Mostra o plano de validação"
            echo "  --resume   : Retoma a partir do último stage salvo"
            echo "  --phase N  : Executa validação de uma fase específica (0-5)"
            echo "  --apply    : Indisponível (requer autorização para operações de infraestrutura)"
            exit 1
            ;;
    esac
    
    if [[ $FAILED -eq 1 ]]; then
        echo ""
        echo -e "${RED}Validação concluída com falhas.${NC}"
        exit 1
    else
        echo ""
        echo -e "${GREEN}Validação concluída com sucesso.${NC}"
        exit 0
    fi
}

main "$@"