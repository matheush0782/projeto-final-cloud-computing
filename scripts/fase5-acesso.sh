#!/usr/bin/env bash
set -euo pipefail
# Utiliza o mesmo PROJETO da automação da PR #1 (scripts/common.sh).
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
carregar_config
exigir_comandos lxc python3
checar_lxd

# Confere o projeto exato, sem formar nomes divergentes.
lx_global project show "$PROJETO" >/dev/null
lxc config set core.https_address :8443

existe_cliente() {
    local nome="$1"
    lxc config trust list --format=json | python3 -c '
import json, sys
nome = sys.argv[1]
clientes = json.load(sys.stdin)
sys.exit(0 if any(c.get("name") == nome for c in clientes) else 1)
' "$nome"
}

ADMIN="admin-${PROJETO}"
OPERADOR="operador-${PROJETO}"

if existe_cliente "$ADMIN"; then
    echo "Administrador ja registrado: $ADMIN (sem criar token duplicado)."
else
    echo "Token do administrador (NAO enviar ao GitHub):"
    lxc config trust add --name "$ADMIN"
fi

if existe_cliente "$OPERADOR"; then
    echo "Operador ja registrado: $OPERADOR (sem criar token duplicado)."
else
    echo "Token restrito do operador (NAO enviar ao GitHub):"
    lxc config trust add --name "$OPERADOR" --restricted --projects "$PROJETO"
fi

printf '\nVerifique os clientes registrados e teste os dois acessos separadamente:\n'
lxc config trust list
