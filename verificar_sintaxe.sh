#!/usr/bin/env bash
# Verificar sintaxe dos scripts da Fase 6

echo "=== Verificando Sintaxe Bash ==="

failed=0
for script in scripts/01-snapshot.sh scripts/02-backup.sh scripts/03-restore.sh scripts/04-limpeza.sh scripts/common.sh scripts/validar-fase6.sh scripts/concluir-projeto.sh; do
    if [ -f "$script" ]; then
        if bash -n "$script" 2>/dev/null; then
            echo "[PASS] $script"
        else
            echo "[FAIL] $script - sintaxe invalida"
            failed=1
        fi
    fi
done

echo ""
echo "=== Verificando Estrutura ==="

for file in tests/test_fase6.sh docs/fase-6/README.md .github/workflows/fase-6.yml; do
    if [ -f "$file" ]; then
        echo "[PASS] $file"
    else
        echo "[FAIL] $file - nao encontrado"
        failed=1
    fi
done

echo ""
if [ $failed -eq 0 ]; then
    echo "[OK] Todos os testes passaram"
    exit 0
else
    echo "[FAIL] Alguns testes falharam"
    exit 1
fi