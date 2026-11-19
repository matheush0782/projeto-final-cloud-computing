
#!/usr/bin/env bash
set -euo pipefail

read -rp "Informe o numero ou identificador da equipe: " EQUIPE

PROJETO="final-equipe${EQUIPE}"

# Conferir se o projeto existe
lxc project show "$PROJETO" > /dev/null

# Habilitar a API HTTPS do LXD
lxc config set core.https_address :8443

# Gerar acesso de administrador
echo "Token do administrador:"
lxc config trust add --name "admin-equipe${EQUIPE}"

# Gerar acesso restrito ao projeto
echo "Token do operador:"
lxc config trust add \
    --name "operador-equipe${EQUIPE}" \
    --restricted \
    --projects "$PROJETO"

echo "Tokens gerados. Registre os clientes para concluir a configuracao."
