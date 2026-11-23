#!/usr/bin/env bash
# Testes automatizados da Fase 6 - validação de estrutura e sintaxe
# Executa testes Python com mock_lxc.py - não executa comandos LXD reais

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Cores para saída
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "Fase 6 - Testes de Validação"
echo "=========================================="

FAILED=0

# Função para verificar se arquivo existe
check_file() {
    local file="$1"
    local desc="$2"
    if [ -f "$ROOT_DIR/$file" ]; then
        echo -e "${GREEN}[OK]${NC} $desc: $file"
    else
        echo -e "${RED}[FAIL]${NC} $desc: $file (não encontrado)"
        FAILED=1
    fi
}

# Função para verificar se diretório existe
check_dir() {
    local dir="$1"
    local desc="$2"
    if [ -d "$ROOT_DIR/$dir" ]; then
        echo -e "${GREEN}[OK]${NC} $desc: $dir"
    else
        echo -e "${RED}[FAIL]${NC} $desc: $dir (não encontrado)"
        FAILED=1
    fi
}

echo ""
echo "=== 1. Verificando estrutura de arquivos ==="

# Scripts da Fase 6
check_file "scripts/01-snapshot.sh" "Script snapshot"
check_file "scripts/02-backup.sh" "Script backup"
check_file "scripts/03-restore.sh" "Script restore"
check_file "scripts/04-limpeza.sh" "Script limpeza"
check_file "scripts/common.sh" "Script common"
check_file "docs/fase-6/README.md" "Documentação Fase 6"

# Profiles LXD
check_file "profiles/perfil-base.yaml" "Profile base"
check_file "profiles/perfil-app.yaml" "Profile app"
check_file "profiles/perfil-db.yaml" "Profile db"
check_file "profiles/perfil-proxy.yaml" "Profile proxy"

# Diretórios
check_dir "profiles" "Diretório profiles"
check_dir "networks" "Diretório networks"
check_dir "networks/prod" "Diretório networks/prod"
check_dir "networks/dev" "Diretório networks/dev"

echo ""
echo "=== 2. Verificando sintaxe Bash ==="

# Verifica sintaxe Bash de cada script
for script in scripts/01-snapshot.sh scripts/02-backup.sh scripts/03-restore.sh scripts/04-limpeza.sh scripts/common.sh; do
    if [ -f "$ROOT_DIR/$script" ]; then
        if bash -n "$ROOT_DIR/$script" 2>/dev/null; then
            echo -e "${GREEN}[OK]${NC} Sintaxe válida: $script"
        else
            echo -e "${RED}[FAIL]${NC} Sintaxe inválida: $script"
            FAILED=1
        fi
    fi
done

echo ""
echo "=== 3. Verificando shebang único ==="

# Verifica se há apenas um shebang por script
for script in scripts/01-snapshot.sh scripts/02-backup.sh scripts/03-restore.sh scripts/04-limpeza.sh scripts/common.sh; do
    if [ -f "$ROOT_DIR/$script" ]; then
        count=$(grep -c '^#!/usr/bin/env bash' "$ROOT_DIR/$script" 2>/dev/null || echo "0")
        if [ "$count" -eq 1 ]; then
            echo -e "${GREEN}[OK]${NC} Shebang único em: $script"
        else
            echo -e "${RED}[FAIL]${NC} Shebang duplicado ou ausente em: $script ($count ocorrências)"
            FAILED=1
        fi
    fi
done

echo ""
echo "=== 4. Verificando ausência de exemplos destrutivos ==="

# Verificar se scripts terminaram com código funcional, não com exemplos
for script in 02-backup.sh 03-restore.sh 04-limpeza.sh; do
    file="$ROOT_DIR/scripts/$script"
    if [ -f "$file" ]; then
        last_lines=$(tail -5 "$file")
        
        if echo "$last_lines" | grep -q '^\./scripts/'; then
            echo -e "${RED}[FAIL]${NC} scripts/$script ainda contém exemplos de comandos no final"
            FAILED=1
        elif echo "$last_lines" | grep -q '^lxc '; then
            echo -e "${RED}[FAIL]${NC} scripts/$script ainda contém comandos lxc de exemplo no final"
            FAILED=1
        else
            echo -e "${GREEN}[OK]${NC} scripts/$script não tem exemplos destrutivos no final"
        fi
    fi
done

echo ""
echo "=== 5. Verificando mock_lxc.py ==="

# Verificar implementações essenciais do mock
MOCK_FILE="$ROOT_DIR/tests/mock_lxc.py"
if [ -f "$MOCK_FILE" ]; then
    # Verificar lxc remote get-default
    if grep -q 'if a == \["remote", "get-default"\]:' "$MOCK_FILE"; then
        echo -e "${GREEN}[OK]${NC} Mock implementa 'lxc remote get-default'"
    else
        echo -e "${RED}[FAIL]${NC} Mock não implementa 'lxc remote get-default'"
        FAILED=1
    fi
    
    # Verificar lxc info
    if grep -q 'if a\[:1\] == \["info"\]' "$MOCK_FILE"; then
        echo -e "${GREEN}[OK]${NC} Mock implementa 'lxc info'"
    else
        echo -e "${RED}[FAIL]${NC} Mock não implementa 'lxc info'"
        FAILED=1
    fi
    
    # Verificar lxc info local
    if grep -q '"local"' "$MOCK_FILE"; then
        echo -e "${GREEN}[OK]${NC} Mock trata 'lxc info local'"
    else
        echo -e "${RED}[FAIL]${NC} Mock não trata 'lxc info local'"
        FAILED=1
    fi
else
    echo -e "${RED}[FAIL]${NC} tests/mock_lxc.py não encontrado"
    FAILED=1
fi

echo ""
echo "=== 6. Verificando workflow GitHub Actions ==="

if [ -f "$ROOT_DIR/.github/workflows/fase-6.yml" ]; then
    echo -e "${GREEN}[OK]${NC} Workflow encontrado: .github/workflows/fase-6.yml"
    
    # Verificar se todos os caminhos do workflow existem
    missing=0
    for path in scripts/01-snapshot.sh scripts/02-backup.sh scripts/03-restore.sh scripts/04-limpeza.sh docs/fase-6/README.md tests/test_fase6.sh; do
        if [[ ! -f "$ROOT_DIR/$path" ]]; then
            echo -e "${RED}[FAIL]${NC} Path no workflow não existe: $path"
            missing=1
        fi
    done
    if [ $missing -eq 0 ]; then
        echo -e "${GREEN}[OK]${NC} Todos os caminhos do workflow existem"
    fi
else
    echo -e "${RED}[FAIL]${NC} Workflow não encontrado: .github/workflows/fase-6.yml"
    FAILED=1
fi

# Verificar workflow antigo (para histórico)
if [ -f "$ROOT_DIR/.github/workflow" ]; then
    echo -e "${YELLOW}[INFO]${NC} Workflow antigo encontrado: .github/workflow (mantido para histórico)"
fi

echo ""
echo "=== 7. Verificando instâncias ==="

# Verificar se scripts definem as 6 instâncias corretamente
for script in 01-snapshot.sh 02-backup.sh 04-limpeza.sh; do
    file="$ROOT_DIR/scripts/$script"
    if [ -f "$file" ]; then
        if grep -q '"proxy"' "$file" && grep -q '"app"' "$file" && grep -q '"db"' "$file" && \
           grep -q '"dev-proxy"' "$file" && grep -q '"dev-app"' "$file" && grep -q '"dev-db"' "$file"; then
            echo -e "${GREEN}[OK]${NC} scripts/$script: todas as 6 instâncias definidas"
        else
            echo -e "${YELLOW}[WARN]${NC} scripts/$script: pode estar faltando alguma instância"
        fi
    fi
done

echo ""
echo "=== 8. Verificando arrays INSTANCES/CONSUMERS ==="

# Verificar balanceamento CONSUMERS
snapshot_script="$ROOT_DIR/scripts/01-snapshot.sh"
if [ -f "$snapshot_script" ]; then
    inst_items=$(grep '^INSTANCES=' "$snapshot_script" | grep -oE '"[^"]*"' | wc -l)
    cons_items=$(grep '^CONSUMERS=' "$snapshot_script" | grep -oE '"[^"]*"' | wc -l)
    echo "  scripts/01-snapshot.sh: INSTANCES=$inst_items, CONSUMERS=$cons_items"
    
    # Verificar se dev-proxy está no CONSUMERS
    if grep 'CONSUMERS=' "$snapshot_script" | grep -q 'dev-proxy'; then
        echo -e "${GREEN}[OK]${NC} dev-proxy está em CONSUMERS"
    else
        echo -e "${YELLOW}[INFO]${NC} dev-proxy não está em CONSUMERS (dev-proxy é leve, sem dados persistentes)"
    fi
fi

# Verificar 02-backup.sh
backup_script="$ROOT_DIR/scripts/02-backup.sh"
if [ -f "$backup_script" ]; then
    # 02-backup.sh usa INSTANCES_PROD, INSTANCES_DEV e CONSUMERS
    if grep -q 'INSTANCES_PROD=' "$backup_script" && grep -q 'INSTANCES_DEV=' "$backup_script" && grep -q 'CONSUMERS=' "$backup_script"; then
        inst_prod=$(grep '^INSTANCES_PROD=' "$backup_script" | grep -oE '"[^"]*"' | wc -l)
        inst_dev=$(grep '^INSTANCES_DEV=' "$backup_script" | grep -oE '"[^"]*"' | wc -l)
        cons_count=$(grep '^CONSUMERS=' "$backup_script" | grep -oE '"[^"]*"' | wc -l)
        echo "  scripts/02-backup.sh: INSTANCES_PROD=$inst_prod, INSTANCES_DEV=$inst_dev, CONSUMERS=$cons_count"
    fi
fi

# Verificar 04-limpeza.sh
limpeza_script="$ROOT_DIR/scripts/04-limpeza.sh"
if [ -f "$limpeza_script" ]; then
    if grep -q 'INSTANCES=' "$limpeza_script"; then
        inst_items=$(grep '^INSTANCES=' "$limpeza_script" | grep -oE '"[^"]*"' | wc -l)
        echo "  scripts/04-limpeza.sh: INSTANCES=$inst_items (sem CONSUMERS - limpa todas as instâncias)"
    fi
fi

echo ""
echo "=========================================="
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}TODOS OS TESTES PASSARAM${NC}"
    echo "=========================================="
    exit 0
else
    echo -e "${RED}SOME TESTS FAILED${NC}"
    echo "=========================================="
    exit 1
fi