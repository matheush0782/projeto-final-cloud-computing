#!/usr/bin/env bash
# Script de teste rápido para validar a Fase 6

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "Fase 6 - Testes de Validacao"
echo "=========================================="

FAILED=0

# 1. Verificar sintaxe Bash
echo ""
echo "=== 1. Sintaxe Bash ==="

for script in 01-snapshot.sh 02-backup.sh 03-restore.sh 04-limpeza.sh common.sh; do
    if [ -f "$ROOT_DIR/scripts/$script" ]; then
        if bash -n "$ROOT_DIR/scripts/$script" 2>/dev/null; then
            echo "[PASS] Sintaxe OK: $script"
        else
            echo "[FAIL] Sintaxe INVALIDA: $script"
            FAILED=1
        fi
    fi
done

# 2. Verificar estrutura
echo ""
echo "=== 2. Estrutura de Arquivos ==="

for file in tests/test_fase6.sh docs/fase-6/README.md .github/workflows/fase-6.yml; do
    if [ -f "$ROOT_DIR/$file" ]; then
        echo "[PASS] $file"
    else
        echo "[FAIL] $file (nao encontrado)"
        FAILED=1
    fi
done

# 3. Verificar mock
echo ""
echo "=== 3. Mock LXD ==="

if grep -q 'remote.*get-default' "$ROOT_DIR/tests/mock_lxc.py" 2>/dev/null; then
    echo "[PASS] Mock: remote get-default"
else
    echo "[FAIL] Mock: remote get-default nao implementado"
    FAILED=1
fi

if grep -q '"local"' "$ROOT_DIR/tests/mock_lxc.py" 2>/dev/null; then
    echo "[PASS] Mock: info local"
else
    echo "[FAIL] Mock: info local nao implementado"
    FAILED=1
fi

# 4. Verificar ausencia de exemplos destrutivos
echo ""
echo "=== 4. Seguranca - Sem exemplos destrutivos ==="

for script in 02-backup.sh 03-restore.sh 04-limpeza.sh; do
    file="$ROOT_DIR/scripts/$script"
    last5=$(tail -5 "$file")
    
    if echo "$last5" | grep -q '^\./scripts/'; then
        echo "[FAIL] scripts/$script tem exemplos no final"
        FAILED=1
    elif echo "$last5" | grep -q '^lxc '; then
        echo "[FAIL] scripts/$script tem comandos LXC no final"
        FAILED=1
    else
        echo "[PASS] scripts/$script sem exemplos destrutivos"
    fi
done

echo ""
echo "=========================================="
if [ "$FAILED" -eq 0 ]; then
    echo "[OK] TODOS OS TESTES PASSARAM"
    exit 0
else
    echo "[FAIL] ALGUNS TESTES FALHARAM"
    exit 1
fi