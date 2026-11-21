#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
for comando in python3 php openssl shellcheck; do
  command -v "$comando" >/dev/null || { printf 'Comando ausente: %s (consulte docs/automacao.md).\n' "$comando" >&2; exit 1; }
done
python3 -c 'import yaml'
printf 'Validação LOCAL: LXD/curl dos testes são simulados; não é evidência da VM.\n'
for arquivo in scripts/*.sh conf/*.sh tests/*.sh; do bash -n "$arquivo"; done
php -l conf/atualiza-url-wp.php
shellcheck -x -P scripts scripts/common.sh scripts/deploy.sh scripts/destroy.sh scripts/monitor.sh scripts/test-limits.sh scripts/registrar-evidencias.sh conf/config-mariadb.sh conf/instala-wp.sh
bash tests/test_fase5_local.sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
printf 'Validações locais concluídas. Testes reais no LXD/navegador continuam pendentes.\n'
