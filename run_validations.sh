#!/usr/bin/env bash
set -euo pipefail

cd /c/Users/mathe/Downloads/projeto-final-cloud-computing

echo "=== Git diff --check ==="
git diff --check && echo "OK"

echo ""
echo "=== bash -n scripts/concluir-projeto.sh ==="
bash -n scripts/concluir-projeto.sh && echo "OK"

echo ""
echo "=== bash -n scripts/validar-fase6.sh ==="
bash -n scripts/validar-fase6.sh && echo "OK"

echo ""
echo "=== bash -n tests/test_fase6.sh ==="
bash -n tests/test_fase6.sh && echo "OK"

echo ""
echo "=== python3 -m pytest tests/test_scripts.py -v ==="
if command -v python3 >/dev/null 2>&1; then
    python3 -m pytest tests/test_scripts.py -v
else
    echo "python3 não disponível"
fi

echo ""
echo "=== bash tests/test_fase6.sh ==="
bash tests/test_fase6.sh

echo ""
echo "=== bash scripts/concluir-projeto.sh --check ==="
bash scripts/concluir-projeto.sh --check

echo ""
echo "=== bash scripts/concluir-projeto.sh --plan ==="
bash scripts/concluir-projeto.sh --plan