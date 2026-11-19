# Integração e automação — fases 7 e 8

O código foi preparado sobre a branch `dev`, commit-base `fdc62f1`, seguindo as páginas 24–26 do PDF da disciplina e a trilha WordPress já existente. **Branch Git `dev` e ambiente LXD DEV são coisas diferentes:** a branch reúne os arquivos da equipe; `ENV` escolhe onde implantar esses mesmos arquivos.

## Preparar uma VM nova

O ambiente de referência é Ubuntu 24.04 com LXD 5.21 LTS. Instale dependências na VM; não reinicialize o LXD da VM existente da equipe.

```bash
sudo apt update
sudo apt install -y git python3 python3-yaml snapd
# Somente se LXD ainda não estiver instalado:
sudo snap install lxd --channel=5.21/stable
sudo usermod -aG lxd "$USER"
```

Saia da sessão e entre novamente para aplicar o grupo `lxd`. Esse grupo dá acesso administrativo ao host; não o conceda a usuários não confiáveis.

```bash
# Somente em instalação LXD nova, ainda não inicializada:
lxd init --minimal
lxc remote switch local
lxc info

git clone -b dev https://github.com/matheush0782/projeto-final-cloud-computing.git
cd projeto-final-cloud-computing
chmod +x scripts/*.sh conf/*.sh
```

Os profiles dos dois ambientes somam 4 GiB de limites de memória, sem contar o host. Recomenda-se memória adicional, preferencialmente uma VM com 6–8 GiB e espaço livre no disco. Os scripts usam containers de sistema e não precisam criar VMs LXD com KVM.

## GitHub → VM existente

Adicione os arquivos de integração na branch `dev`, faça commit e push no computador da equipe. Na VM, dentro do clone:

```bash
git status
git switch dev
git pull --ff-only origin dev
chmod +x scripts/*.sh conf/*.sh
```

Se houver alterações locais, preserve-as antes de atualizar. Não use `reset --hard`. `git pull` somente atualiza arquivos; **não executa o deploy**.

Antes da primeira execução na VM já usada:

```bash
lxc project show final-equipeN
lxc list --project final-equipeN
lxc storage volume list pool-final --project final-equipeN
lxc profile show perfil-base --project default
```

O nome `final-equipeN` foi mantido porque aparece nas evidências existentes. Se a equipe usa outro nome, defina `export PROJETO=nome-correto` em todos os terminais. Não crie um projeto novo por engano sobre dados já existentes.

O desenho usa `features.profiles=false`, `features.networks=false` e `features.storage.volumes=true`. Perfis e bridges vêm do projeto `default`, enquanto instâncias e volumes customizados ficam no projeto da equipe. Os scripts usam `--project` em cada comando, sem alterar o projeto selecionado no terminal. O remoto padrão deve ser `local`. [1] [2]

Se as opções do projeto existente forem incompatíveis, o deploy para: não muda o isolamento automaticamente. Um profile compartilhado que difere do YAML e está em uso também faz o deploy parar antes de excluir instâncias. Revise a diferença com a equipe; não aplique um profile às cegas. Bridges incompatíveis e pool com driver diferente de `dir` não são reconfigurados automaticamente.

## Configurar e implantar

Veja primeiro os nomes e portas:

```bash
ENV=prod ./scripts/deploy.sh --dry-run
ENV=dev ./scripts/deploy.sh --dry-run
```

`--dry-run` é um plano offline: não consulta nem modifica o LXD e não garante ausência de conflitos reais.

```bash
# Endereço usado no navegador, sem protocolo ou porta:
export VM_HOST=127.0.0.1
# Ou substitua pelo IP real alcançável da VM:
# export VM_HOST=192.168.1.100

read -rsp 'Senha do banco PROD: ' DB_PASS_PROD; echo
export DB_PASS_PROD
read -rsp 'Senha do banco DEV: ' DB_PASS_DEV; echo
export DB_PASS_DEV

ENV=prod ./scripts/deploy.sh
ENV=dev ./scripts/deploy.sh
unset DB_PASS DB_PASS_PROD DB_PASS_DEV
```

Use senhas fortes com letras, números e `_ @ % + = . : , -`. Não há senha padrão no código. `DB_PASS` tem prioridade sobre a variável específica de cada ambiente, então não a deixe exportada se quiser senhas distintas. Os scripts não imprimem a senha, mas ela é passada como argumento aos scripts do guest e pode ser vista nos processos por usuários com acesso à VM. Não use `bash -x` com credenciais. Não publique `.env`, dumps, chaves ou `wp-config.php`.

PROD cria `proxy/app/db` nos IPs `10.10.10.10/.11/.12`, com HTTP `8081`, HTTPS `8444`, `vol-db` e `vol-uploads`. DEV cria `dev-proxy/dev-app/dev-db` nos IPs `10.10.20.10/.11/.12`, com HTTP `8082`, HTTPS `8445`, `dev-vol-db` e `dev-vol-uploads`. DEV tem dados próprios e começa vazio; não clona PROD.

O deploy cria os recursos ausentes, reaproveita `profiles/`, anexa volumes antes do primeiro boot e aguarda cloud-init. Configura MariaDB, WordPress e Nginx com os IPs do ambiente. Gera certificado/chave dentro do proxy e publica as duas portas. Verifica serviços, a conexão PHP/MariaDB e uma resposta HTTP interna. `BOOT_TIMEOUT` controla a espera, com padrão 900 segundos. Falhas deixam recursos parciais para diagnóstico; não há rollback destrutivo.

Em banco novo, conclua o assistente WordPress no navegador. O Nginx atende HTTPS com certificado autoassinado, mas a URL canônica WordPress é HTTP: algumas rotas podem redirecionar para HTTP. Esta entrega não força HTTPS exclusivo. O certificado muda na recriação do proxy.

No VirtualBox com NAT, além da porta `8081` já usada, encaminhe `8082`, `8444` e `8445` do computador hospedeiro para as mesmas portas da VM, se precisar acessá-las pelo host. Confira firewall e conectividade. Não abra a API LXD na rede para usar o monitor. [3] [4]

## Backup e recriação que mantém volumes

O deploy padrão **recusa instâncias existentes**, em vez de apagar o site silenciosamente. Antes de recriar PROD:

```bash
mkdir -p backup
chmod 700 backup
umask 077
lxc exec --project final-equipeN db -- mariadb-dump --single-transaction wordpress > backup/wordpress-prod.sql
lxc exec --project final-equipeN app -- tar -C /var/www/html -czf - . > backup/wordpress-files-prod.tar.gz
```

Os comandos pressupõem PROD ativo e banco padrão `wordpress`. Confira os arquivos e mantenha cópia privada fora da VM. O backup de arquivos contém configurações sensíveis e não deve ir ao GitHub. Em site movimentado, coordene uma janela sem alterações para consistência entre banco e arquivos.

```bash
ENV=prod ./scripts/destroy.sh --dry-run
ENV=prod ./scripts/destroy.sh
# Digite final-equipeN/prod para confirmar.
# Informe novamente VM_HOST e a senha conforme a seção anterior.
ENV=prod ./scripts/deploy.sh
```

Alternativa: `ENV=prod ./scripts/deploy.sh --recreate` pede confirmação e remove os três containers antes de criar. `--yes` é a confirmação explícita para execução não interativa; só use após revisar o plano e o backup.

Os volumes retidos mantêm posts, usuários/opções do banco e uploads. **Discos raiz, snapshots das instâncias, certificados, logs e temas/plugins extras no root são perdidos.** Para preservar customizações de arquivos, restaure o backup. O core WordPress é reinstalado em root novo; `latest.tar.gz` e o alias Ubuntu não fixam versões byte a byte. A reprodução é da infraestrutura e serviço, não de artefatos imutáveis.

Reanexar o banco existente pode executar scripts de instalação dos pacotes novamente; esse comportamento deve ser validado na VM alvo. A configuração reaplica a senha do usuário da aplicação com `ALTER USER`, então coordene a senha escolhida com a equipe.

## Exclusão de dados e teste do zero

```bash
# DEV: remove containers, conserva banco e uploads
ENV=dev ./scripts/destroy.sh

# DEV descartável: primeiro revise o plano de exclusão dos dados
ENV=dev ./scripts/destroy.sh --volumes --dry-run
# Execute apenas se os dados DEV puderem ser apagados:
ENV=dev ./scripts/destroy.sh --volumes
ENV=dev ./scripts/deploy.sh
```

`destroy.sh` remove somente os três nomes exatos e, com `--volumes`, os dois volumes exatos do ambiente. Não remove outros volumes `vol-*`, a rede, pool, projeto ou profiles. Se uma exclusão falha, interrompe antes de apagar volumes; se um volume alvo estiver ligado a um recurso fora da lista, aborta antes de apagar instâncias.

O comando do PDF `ENV=prod ./scripts/destroy.sh --volumes` apaga definitivamente posts e imagens de PROD. Não o execute sobre o CloudPress atual sem backup verificado e acordo da equipe. Comece em DEV descartável. Se a avaliação exigir PROD do zero, reserve uma janela e documente a restauração ou o preenchimento do site.

## Variáveis, funções, condições e parâmetros Bash

`ENV="${ENV:-prod}"` usa o valor informado ou `prod` como padrão. `ENV=dev ./scripts/deploy.sh` define a variável só para essa execução; `export VM_HOST=...` a disponibiliza aos próximos comandos. `PREFIXO` permite usar os mesmos comandos para `app` e `dev-app`. Aspas como `"$PROJETO"` impedem separação indevida de argumentos.

Uma função agrupa comandos reutilizáveis. `criar_instancia db 12` chama a função com `$1=db` e `$2=12`; `local` restringe variáveis à função. Em `conf/config-mariadb.sh`, os quatro argumentos são IP, banco, usuário e senha. No instalador WordPress, os três primeiros são IP do banco, senha e URL; banco/usuário são opcionais.

`case "$ENV" in` seleciona PROD/DEV e recusa erros de digitação. `if` avalia o retorno de um comando: zero significa sucesso, outro número significa falha. `while (($#))` lê as opções passadas; `shift` consome argumentos. Arrays como `VOLUMES=(...)` representam uma lista exata, percorrida com `for`, sem expandir nomes por um filtro amplo.

`set -euo pipefail` interrompe erros não tratados, detecta variáveis não definidas e falhas em pipelines. Não substitui testes de segurança: erros esperados, como `timeout` retornando 124, precisam de tratamento explícito. `trap ... EXIT` remove somente os temporários do script, não os recursos LXD.

O helper `lx()` acrescenta `--project="$PROJETO"`. `lx_global()` trata os recursos compartilhados em `default`. Essa separação evita que o projeto selecionado previamente no terminal decida onde os dados serão removidos.

## Monitoramento, testes e evidências

```bash
./scripts/monitor.sh --all
ENV=dev ./scripts/monitor.sh --once
ENV=prod ./scripts/test-limits.sh
ENV=dev ./scripts/test-limits.sh
# Terminal 1: ENV=dev ./scripts/monitor.sh
# Terminal 2: carga de 20 segundos só em dev-app
ENV=dev ./scripts/test-limits.sh --load
```

Consulte [monitoramento.md](monitoramento.md) para interpretar CPU, memória, disco e cgroups. A CPU apresentada em `u` é tempo acumulado, não percentual. O disco é observado, mas o profile atual/pool `dir` não configura quota de disco. Não há teste OOM de memória.

Validação sem LXD real:

```bash
for arquivo in scripts/*.sh conf/*.sh; do bash -n "$arquivo" || exit 1; done
python3 tests/test_scripts.py
# PHP CLI e ShellCheck são necessários só para estas verificações adicionais:
sudo apt install -y php-cli shellcheck
python3 tests/test_wp_config.py
shellcheck -x scripts/*.sh conf/*.sh
```

Os testes Python colocam o LXC falso no PATH de um processo temporário: não acessam o daemon real. O segundo arquivo testa o gerador PHP e a cópia do core com fixtures, inclusive uploads retidos. Nada disso deve ser apresentado como evidência real da VM.

Após a execução real, salve em `docs/evidencias/`: lista dos seis containers; navegador em DEV; verificação HTTP/HTTPS; publicação/imagem antes e depois da recriação; painel; limites de CPU/memória; CPU de `dev-app` antes/durante/depois da carga. Registre data, commit, projeto e resultado. Não copie senhas ou o conteúdo completo de `wp-config.php`.

```bash
mkdir -p docs/evidencias
{ date -Is; git rev-parse --short HEAD; lxc list --project final-equipeN; } > docs/evidencias/fase7-prod-dev.txt
ENV=dev ./scripts/monitor.sh --once > docs/evidencias/fase8-monitor-dev.txt
ENV=dev ./scripts/test-limits.sh > docs/evidencias/fase8-limites-dev.txt
```

Esses comandos só coletam informações; não confirmam sucesso por si mesmos. Revise as saídas e relate também avisos/falhas. A validação real da VM permanece pendente nesta entrega.

## Referências

PDF da atividade: WordPress nas páginas 8–10, automação nas páginas 24–25 e monitoramento na página 26.

[1]: https://canonical.com/lxd/docs/default/howto/projects_work/ "LXD — Working with projects"
[2]: https://raw.githubusercontent.com/canonical/lxd/lxd-5.21.7/lxd/project/project.go "LXD 5.21.7 — Escopo de volumes, redes e perfis"
[3]: https://canonical.com/lxd/docs/default/reference/devices_proxy/ "LXD — Proxy devices"
[4]: https://canonical.com/lxd/docs/default/metrics/ "LXD — Monitoring metrics"
