# Validação local da integração

Data: 19/11/2026. Base: branch `dev`, commit `fdc62f1` do repositório da equipe.

A suíte `python3 tests/test_scripts.py` passou nos **23 testes de fluxo**, usando exclusivamente um cliente LXC simulado no PATH temporário do processo. Inclui isolamento PROD/DEV, preservação e exclusão restrita dos volumes, confirmação, falhas de API/exclusão, proteção de perfis compartilhados, painel, checagem de limites simulados e carga restrita a `dev-app` com timeout no guest.

`python3 tests/test_wp_config.py` passou nos **2 testes com fixtures**. O primeiro executa o gerador em PHP CLI 8.3, verifica sintaxe PHP, caracteres especiais, geração de chave de autenticação e repetição sem alteração indevida. O segundo executa somente a função de cópia em diretórios temporários, verificando que uploads e tema existente são preservados e que o tema padrão/sample são instalados quando ausentes.

A sintaxe Bash foi verificada arquivo a arquivo com `bash -n`. `shellcheck -x scripts/*.sh conf/*.sh` e `git diff --check` terminaram sem erros. O patch foi conferido com `git apply --check` em uma cópia limpa do commit-base.

**Nenhum desses resultados comprova execução real em LXD.** Não houve deploy/destroy/monitoramento na VM da equipe, teste de instalação dos pacotes via cloud-init, validação real do MariaDB/Nginx/Apache, limites reais de cgroups, acesso pelo VirtualBox ou teste HTTP/HTTPS externo.

As evidências históricas de `docs/evidencias/` foram preservadas e não foram reclassificadas como testes desta integração. As capturas/saídas reais das fases 7 e 8 devem ser coletadas na VM, seguindo `docs/automacao.md` e `docs/monitoramento.md`. Não houve commit/push no GitHub.
