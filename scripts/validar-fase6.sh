#!/usr/bin/env bash
# Validação da Etapa 1 da Fase 6 - Problemas críticos
# Executa verificações sem modificar o estado da VM

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Cores para saída
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

FAILED=0
PASSED=0

section() {
    echo ""
    echo -e "${BLUE}=== $1 ===${NC}"
}

pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAILED=$((FAILED + 1))
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Função auxiliar para extrair elementos de um array bash
# Uso: extract_array_elements "ARRAY_NAME" "file.sh"
# Retorna os elementos separados por espaço
extract_array_elements() {
    local array_name="$1"
    local file="$2"
    local line
    line=$(grep -E "^${array_name}=" "$file" 2>/dev/null | head -1)
    if [[ -z "$line" ]]; then
        return 1
    fi
    # Extrair conteúdo entre parênteses
    local content
    content="${line#*=}"
    content="${content#\(}"
    content="${content%\)}"
    # Remover aspas e separar por espaço
    echo "$content" | sed 's/"//g'
}

# Função auxiliar para verificar se elemento está no array
# Uso: array_contains "element" "ARRAY_NAME" "file.sh"
array_contains() {
    local element="$1"
    local array_name="$2"
    local file="$3"
    local elements
    elements=$(extract_array_elements "$array_name" "$file")
    if [[ -z "$elements" ]]; then
        return 1
    fi
    for e in $elements; do
        if [[ "$e" == "$element" ]]; then
            return 0
        fi
    done
    return 1
}

# 1. Verificar git status
section "1. Estado do repositório Git"

CD=$(git -C "$ROOT_DIR" rev-parse --git-dir 2>/dev/null || echo "not a git repo")
if [[ "$CD" != "not a git repo" ]]; then
    branch=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    echo "Branch atual: $branch"
    pass "Branch atual: $branch"
else
    fail "Não é um repositório git"
fi

# 2. Verificar arquivos modificados
section "2. Arquivos modificados"

MODIFIED=$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null | grep ' M ' || true)
if [[ -n "$MODIFIED" ]]; then
    echo "$MODIFIED"
    warn "Arquivos modificados (não staged):"
    pass "Arquivos modificados identificados"
else
    pass "Nenhum arquivo modificado"
fi

# 3. Verificar arquivos novos não trackeados
section "3. Arquivos novos"

UNTRACKED=$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null | grep '^??' || true)
if [[ -n "$UNTRACKED" ]]; then
    echo "$UNTRACKED"
    warn "Arquivos novos não trackeados:"
    pass "Arquivos novos identificados"
else
    pass "Nenhum arquivo novo"
fi

# 4. Verificar scripts da Fase 6 existentes
section "4. Scripts da Fase 6"

for script in 01-snapshot.sh 02-backup.sh 03-restore.sh 04-limpeza.sh; do
    if [[ -f "$ROOT_DIR/scripts/$script" ]]; then
        pass "scripts/$script existe"
    else
        fail "scripts/$script não encontrado"
    fi
done

# 5. Verificar common.sh
section "5. Script common.sh"

if [[ -f "$ROOT_DIR/scripts/common.sh" ]]; then
    pass "scripts/common.sh existe"
else
    fail "scripts/common.sh não encontrado"
fi

# 6. Verificar documentação da Fase 6
section "6. Documentação da Fase 6"

if [[ -f "$ROOT_DIR/docs/fase-6/README.md" ]]; then
    pass "docs/fase-6/README.md existe"
else
    fail "docs/fase-6/README.md não encontrado"
fi

# 7. Verificar workflow GitHub Actions
section "7. Workflow GitHub Actions"

if [[ -f "$ROOT_DIR/.github/workflows/fase-6.yml" ]]; then
    pass ".github/workflows/fase-6.yml existe"
    
    # Verificar se todos os caminhos do workflow existem
    missing=0
    for path in scripts/01-snapshot.sh scripts/02-backup.sh scripts/03-restore.sh scripts/04-limpeza.sh docs/fase-6/README.md tests/test_fase6.sh; do
        if [[ ! -f "$ROOT_DIR/$path" ]]; then
            fail "path no workflow não existe: $path"
            missing=1
        fi
    done
    if [[ $missing -eq 0 ]]; then
        pass "Todos os caminhos do workflow existem"
    fi
else
    fail ".github/workflows/fase-6.yml não encontrado"
fi

# 8. Verificar test_fase6.sh
section "8. Testes da Fase 6"

if [[ -f "$ROOT_DIR/tests/test_fase6.sh" ]]; then
    if [[ -x "$ROOT_DIR/tests/test_fase6.sh" ]]; then
        pass "tests/test_fase6.sh existe e é executável"
    else
        warn "tests/test_fase6.sh existe mas não é executável"
    fi
else
    fail "tests/test_fase6.sh não encontrado"
fi

# 9. Verificar mock_lxc.py
section "9. Mock LXD"

if [[ -f "$ROOT_DIR/tests/mock_lxc.py" ]]; then
    pass "tests/mock_lxc.py existe"
    
    # Verificar implementações essenciais
    if grep -q 'remote.*get-default' "$ROOT_DIR/tests/mock_lxc.py"; then
        pass "mock_lxc.py implementa 'remote get-default'"
    else
        fail "mock_lxc.py não implementa 'remote get-default'"
    fi
    
    if grep -q 'if a\[:1\] == \["info"\]' "$ROOT_DIR/tests/mock_lxc.py"; then
        pass "mock_lxc.py implementa 'info'"
    else
        fail "mock_lxc.py não implementa 'info'"
    fi
    
    if grep -q '"local"' "$ROOT_DIR/tests/mock_lxc.py"; then
        pass "mock_lxc.py trata 'local' em 'lxc info'"
    else
        fail "mock_lxc.py não trata 'lxc info local'"
    fi
else
    fail "tests/mock_lxc.py não encontrado"
fi

# 10. Verificar ausência de exemplos destrutivos
section "10. Exemplos destrutivos (verificação final)"

# Verificar se scripts terminaram com código funcional, não com exemplos
for script in 02-backup.sh 03-restore.sh 04-limpeza.sh; do
    file="$ROOT_DIR/scripts/$script"
    if [[ -f "$file" ]]; then
        # Verificar se não há comandos lxc de exemplo no final
        last_lines=$(tail -5 "$file")
        
        if echo "$last_lines" | grep -q '^\./scripts/'; then
            fail "scripts/$script ainda contém exemplos de comandos no final"
        elif echo "$last_lines" | grep -q '^lxc '; then
            fail "scripts/$script ainda contém comandos lxc de exemplo no final"
        else
            pass "scripts/$script não tem exemplos destrutivos no final"
        fi
    fi
done

# 11. Verificar arrays INSTANCES vs CONSUMERS
section "11. Verificação de arrays INSTANCES/CONSUMERS"

# Analisar cada script que define esses arrays
for script in 01-snapshot.sh 02-backup.sh 04-limpeza.sh; do
    file="$ROOT_DIR/scripts/$script"
    if [[ -f "$file" ]]; then
        # Extrair elementos dos arrays
        inst_elements=$(extract_array_elements "INSTANCES" "$file" 2>/dev/null)
        cons_elements=$(extract_array_elements "CONSUMERS" "$file" 2>/dev/null)
        
        if [[ -n "$inst_elements" ]]; then
            inst_count=0
            for e in $inst_elements; do inst_count=$((inst_count + 1)); done
            echo "scripts/$script: INSTANCES ($inst_count elementos): $inst_elements"
        else
            warn "scripts/$script: array INSTANCES não encontrado ou vazio"
        fi
        
        if [[ -n "$cons_elements" ]]; then
            cons_count=0
            for e in $cons_elements; do cons_count=$((cons_count + 1)); done
            echo "scripts/$script: CONSUMERS ($cons_count elementos): $cons_elements"
        else
            warn "scripts/$script: array CONSUMERS não encontrado ou vazio"
        fi
        
        # Verificar se dev-proxy está em CONSUMERS (apenas informativo - pode ser intencional)
        if array_contains "dev-proxy" "CONSUMERS" "$file"; then
            pass "scripts/$script: dev-proxy está em CONSUMERS"
        elif array_contains "dev-proxy" "INSTANCES" "$file"; then
            warn "scripts/$script: dev-proxy está em INSTANCES mas NÃO em CONSUMERS (pode ser intencional - dev-proxy não consome volumes)"
        fi
        
        # Verificar se dev-db está em CONSUMERS
        if array_contains "dev-db" "CONSUMERS" "$file"; then
            pass "scripts/$script: dev-db está em CONSUMERS"
        elif array_contains "dev-db" "INSTANCES" "$file"; then
            warn "scripts/$script: dev-db está em INSTANCES mas NÃO em CONSUMERS (dev-db possui volume dev-vol-db)"
        fi
        
        # Verificar se proxy está em CONSUMERS
        if array_contains "proxy" "INSTANCES" "$file" && ! array_contains "proxy" "CONSUMERS" "$file"; then
            warn "scripts/$script: proxy está em INSTANCES mas NÃO em CONSUMERS (proxy não possui volume persistente)"
        fi
        
        # Verificar se app e db estão em CONSUMERS
        for consumer in "app" "db"; do
            if array_contains "$consumer" "INSTANCES" "$file" && ! array_contains "$consumer" "CONSUMERS" "$file"; then
                warn "scripts/$script: $consumer está em INSTANCES mas NÃO em CONSUMERS ($consumer possui volume)"
            fi
        done
        
        # Verificar dev-app e dev-db
        for consumer in "dev-app" "dev-db"; do
            if array_contains "$consumer" "INSTANCES" "$file" && ! array_contains "$consumer" "CONSUMERS" "$file"; then
                warn "scripts/$script: $consumer está em INSTANCES mas NÃO em CONSUMERS ($consumer possui volume)"
            fi
        done
    fi
done

# 12. Resumo
section "Resumo"

echo ""
echo -e "Total PASSED: ${GREEN}$PASSED${NC}"
echo -e "Total FAILED: ${RED}$FAILED${NC}"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}Validação concluída com sucesso!${NC}"
    exit 0
else
    echo -e "${RED}Validação concluída com falhas.${NC}"
    exit 1
fi