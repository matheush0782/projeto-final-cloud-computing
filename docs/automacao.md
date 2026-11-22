# Automação do Samuel integrada à Fase 5

Esta revisão parte da `dev` no commit `8145908`, que já recebeu a Fase 5 pela PR #3. A PR #1 de automação foi fechada sem merge; por isso, os arquivos do Samuel foram reaproveitados seletivamente, sem importar `.DS_Store` nem a exclusão das evidências antigas. Os scripts e templates atuais da Fase 5 foram preservados.

## Estratégia única de certificados

O certificado do WordPress agora é assinado pela **CA própria da Fase 5**. O deploy não cria mais um certificado de serviço autoassinado isolado para depois substituí-lo. A própria CA é uma raiz autoassinada, como esperado nesse laboratório; o certificado do serviço é assinado por ela.

No template HTTPS, o redirecionamento e os cabeçalhos enviados ao WordPress usam o host fixo derivado de `IP_SITE` e da porta HTTPS do ambiente. O valor recebido no cabeçalho `Host` pelo cliente não é reutilizado para formar o redirecionamento nem encaminhado ao WordPress.

`scripts/fase5-tls.sh` é o único responsável por gerar/reutilizar os materiais TLS, instalar os certificados no Nginx, publicar HTTPS e atualizar `WP_HOME`/`WP_SITEURL` com `conf/atualiza-url-wp.php`. Esse atualizador aceita a formatação com espaços do instalador WordPress.

Os materiais locais ficam em `conf/tls/prod/` ou `conf/tls/dev/`, ignorados pelo Git. Dentro dos proxies, os caminhos são `/etc/nginx/ssl/servico.crt` e `/etc/nginx/ssl/servico.key`. O template inicial `conf/nginx-servico.conf` atende somente HTTP; o template `conf/nginx-servico-https.conf` da Fase 5 ativa TLS e redireciona HTTP para HTTPS.

A Fase 5 verifica/atualiza `porta-https` em vez de adicioná-lo duas vezes. O deploy delega essa publicação à Fase 5. Na recriação, os materiais locais existentes são reutilizados: a CA não precisa ser criada novamente nem reimportada, se endereços e certificados continuarem válidos. Nunca envie `conf/tls/`, chaves privadas ou backups ao GitHub.

## Portas e ambientes

O configurador MariaDB recebe o IP do próprio container (`DB_IP`) e o IP da aplicação (`APP_IP`). O serviço escuta somente no IP privado do container DB, enquanto o usuário SQL continua restrito ao IP do container APP.

PROD usa `proxy`, `app` e `db` em `10.10.10.10`, `.11` e `.12`, com HTTP **8081** e HTTPS WordPress **8444**. DEV usa `dev-proxy`, `dev-app` e `dev-db` em `10.10.20.10`, `.11` e `.12`, com HTTP **8082** e HTTPS WordPress **8445**.

**8443 é a API/UI do LXD, não o WordPress.**

O script `scripts/fase5-acesso.sh` configura a API do LXD para escutar somente em `127.0.0.1:8443`. Os comandos `lxc` executados dentro da VM continuam usando o socket local; para uma conexão administrativa HTTPS a partir de outra máquina, utilize um túnel SSH em vez de expor a API em todas as interfaces. O deploy, o monitor e a coleta de evidências não configuram essa porta nem criam clientes administrativos. A abertura do painel em `https://127.0.0.1:8443` não comprova HTTPS do site.

Depois de ativar TLS, 8081/8082 redirecionam para 8444/8445: não espere que o site continue com URL canônica HTTP. Para manter apenas HTTP enquanto a equipe organiza o TLS, use `--http-only`. Isso não ativa a Fase 5 nem publica 8444/8445 nesse deploy.

## Pré-requisitos da VM

Ubuntu 24.04, LXD local inicializado, Bash, Python 3/PyYAML e `timeout`. A integração TLS também precisa de OpenSSL e curl no host. O profile da aplicação precisa disponibilizar PHP CLI, além de Apache/PHP; confirme os pacotes se cloud-init falhar.

```bash
sudo apt update
sudo apt install -y python3 python3-yaml openssl curl
lxc remote switch local
lxc info
lxc project show final-equipeN
lxc list --project final-equipeN
```

Não reinicialize/reinstale o LXD da VM da equipe. O projeto padrão dos scripts é `final-equipeN`, conforme as evidências. Se o nome real for outro, use `export PROJETO=nome-correto` em todos os terminais.

O projeto precisa de perfis/redes compartilhados (`features.profiles=false`, `features.networks=false`) e volumes próprios (`features.storage.volumes=true`). O deploy cria essas opções apenas em projeto novo. Se o projeto existente ou os profiles compartilhados forem incompatíveis, ele para para revisão; não altera o isolamento ou recursos em uso silenciosamente.

## Primeiro deploy em DEV

Confira o IP real da interface de rede da VM com `ip -br -4 addr`. Não use o endereço de uma bridge `net-prod/net-dev` como `IP_VM`. No VirtualBox NAT, `10.0.2.15` é comum, mas é apenas exemplo e deve ser conferido.

```bash
export PROJETO=final-equipeN
export VM_HOST=127.0.0.1
export IP_SITE=127.0.0.1
# Substitua o exemplo pelo IP real da sua VM:
export IP_VM=10.0.2.15

read -rsp 'Senha do banco DEV: ' DB_PASS_DEV; echo
export DB_PASS_DEV
ENV=dev bash scripts/deploy.sh --dry-run
ENV=dev bash scripts/deploy.sh
unset DB_PASS_DEV
```

`IP_SITE` é o IPv4 utilizado no navegador, sem protocolo/porta. O padrão é `VM_HOST`; na integração TLS, utilize IPv4 porque esse é o contrato atual da Fase 5. O certificado inclui `IP_VM`, `IP_SITE`, loopback e `servico.lab`. Se optar pelo domínio, sua resolução e a URL WordPress precisam ser alinhadas com a equipe; este fluxo usa IPv4.

O deploy instala/configura o serviço, publica HTTP e executa a Fase 5. Ela atualiza a URL canônica para `https://IP_SITE:8445` em DEV ou `:8444` em PROD. Se o banco estiver vazio, conclua o assistente WordPress no navegador. DEV não copia automaticamente o conteúdo de PROD.

Para começar somente com HTTP:

```bash
ENV=dev bash scripts/deploy.sh --http-only
# Depois, quando IP_VM/IP_SITE e encaminhamentos estiverem conferidos:
ENV=dev bash scripts/fase5-tls.sh
```

Não execute o deploy novamente por cima de instâncias existentes para somente atualizar TLS. Reexecute `fase5-tls.sh`, que já é idempotente, com os mesmos endereços. Materiais TLS incompletos, expirados ou com SAN incompatível exigem revisão; não apague a CA às cegas.

As senhas aceitam letras, números e `_ @ % + = . : , -` e não ficam embutidas no código. `DB_PASS` tem prioridade sobre `DB_PASS_PROD/DEV`; remova-a do ambiente se quiser credenciais distintas. Leia a senha com `read -rsp`, como no exemplo, para não digitar seu valor literal no histórico do terminal. Remova as variáveis do seu terminal após o uso.

## Senha por stdin e proteção do wp-config.php

Na correção de segurança da PR #4, o deploy retira `DB_PASS`, `DB_PASS_PROD` e `DB_PASS_DEV` do ambiente dos comandos filhos depois de selecionar a senha. MariaDB, instalador WordPress e checagem de conexão PHP recebem o valor por pipe em **stdin**, com `lxc exec --mode=non-interactive`; a senha não aparece nos argumentos desses processos. Não use `--disable-stdin`, pois impediria o recebimento. [2]

Os três arquivos `scripts/deploy.sh`, `conf/config-mariadb.sh` e `conf/instala-wp.sh` precisam ser atualizados juntos. As interfaces internas agora são:

```text
config-mariadb.sh --password-stdin DB_IP APP_IP BASE USUARIO
instala-wp.sh --password-stdin DB_HOST URL [DB_NAME=wordpress] [DB_USER=wpuser]
```

Esses scripts são executados como root dentro dos containers pelo deploy, não diretamente no host da VM. Recebem somente uma linha de senha no stdin; aceitam EOF após a linha, mas rejeitam entrada vazia, linhas extras ou CR. A chamada antiga com senha em argumento foi deliberadamente desativada e retorna instrução de uso sem reproduzir seus argumentos.

Não há arquivo de senha nomeado no transporte do host para os containers. O instalador ainda precisa gerar um `wp-config.php` temporário com credenciais: ele fica no diretório criado por `mktemp`, com `umask 077`, e é removido pelo `trap EXIT`, inclusive em falhas. INT/TERM tratáveis levam à saída e à limpeza; SIGKILL, queda de energia ou falha de disco não permitem garantir execução de traps. O gerador PHP recebe a senha por ambiente controlado dentro do container, não por argv. Isso não impede que root inspecione memória, ambiente ou o próprio arquivo final.

Os scripts de credenciais desativam xtrace/verbose antes de ler a senha, e erros do SQL que contém credenciais são suprimidos para não revelar a consulta em logs. Mesmo assim, não grave a digitação de credenciais nem use rastreamento externo: revise os registros antes de publicar e não exponha variáveis do terminal, `wp-config.php` ou configurações privadas.

O arquivo final `/var/www/html/wp-config.php` recebe **`root:www-data` e modo `0640`**. Apache/PHP consegue lê-lo pelo grupo, mas `www-data` não tem permissão de escrita direta. A normalização dos demais arquivos exclui o wp-config para não torná-lo temporariamente `0644`. O atualizador PHP da Fase 5 preserva proprietário, grupo e modo quando altera as URLs.

Essa mudança protege a escrita direta no arquivo, não é um isolamento completo do WordPress: o diretório do site continua pertencendo a `www-data`, mantendo o comportamento existente. Um processo com escrita no diretório pai ainda pode tentar remover/substituir o arquivo; proteção contra isso exigiria uma política adicional para diretórios/atualizações, fora desta correção. Não declare que o site ficou imutável.

Copiar os scripts para o GitHub ou fazer `git pull` não muda as permissões de um WordPress já instalado. Para corrigir o arquivo existente sem recriar containers, faça backup, confirme ambiente/projeto e combine a intervenção. Exemplo para **DEV**; em PROD, selecione `APP=app` somente após conferir que é o destino desejado:

```bash
APP=dev-app
lxc --project="$PROJETO" exec "$APP" -- test -f /var/www/html/wp-config.php
lxc --project="$PROJETO" exec "$APP" -- stat -c '%U:%G %a %n' /var/www/html/wp-config.php
lxc --project="$PROJETO" exec "$APP" -- chown root:www-data /var/www/html/wp-config.php
lxc --project="$PROJETO" exec "$APP" -- chmod 0640 /var/www/html/wp-config.php
lxc --project="$PROJETO" exec "$APP" -- stat -c '%U:%G %a %n' /var/www/html/wp-config.php
lxc --project="$PROJETO" exec "$APP" -- runuser -u www-data -- test -r /var/www/html/wp-config.php
lxc --project="$PROJETO" exec "$APP" -- runuser -u www-data -- test ! -w /var/www/html/wp-config.php
```

Os dois últimos comandos devem terminar com código 0. Confira também o site no navegador; não imprima o conteúdo do wp-config para provar leitura. O procedimento não altera banco, URLs ou volumes e não exige `destroy.sh`/`--recreate`.

## Remoção: o que se perde

`destroy.sh` e `deploy.sh --recreate` excluem os containers do ambiente, **discos raiz e snapshots das instâncias**. Por padrão, mantêm os volumes personalizados de banco e uploads. Temas/plugins extras, configurações, logs e certificados que existam apenas no root do container não são preservados. A cópia local de `conf/tls/` permanece na VM e pode reinstalar os certificados na recriação.

`destroy.sh --volumes` também apaga os dois volumes do ambiente: os posts/usuários/opções do banco e os uploads podem ser perdidos definitivamente. Nem `--yes` sozinho permite apagar esses volumes: existe uma confirmação adicional específica.

```bash
# Plano offline; nenhum recurso LXD é consultado ou alterado:
ENV=dev bash scripts/destroy.sh --volumes --dry-run

# Interativo: confirma instâncias e depois APAGAR-VOLUMES:final-equipeN/dev
ENV=dev bash scripts/destroy.sh --volumes

# Não interativo, SOMENTE para DEV descartável e após backup/revisão:
ENV=dev bash scripts/destroy.sh --volumes --yes --confirm-volumes final-equipeN/dev
```

Se `PROJETO` tiver outro nome, a confirmação precisa usar esse nome. O token de PROD não serve para DEV nem vice-versa. Uma confirmação errada ou ausente interrompe antes de remover instâncias/volumes. São removidos somente nomes exatos, nunca um filtro amplo `vol-*`; redes, pool, projeto e profiles permanecem. [1]

## Backup e reconstrução com persistência

Antes de recriar PROD, faça backup verificado e mantenha uma cópia privada fora da VM. Os comandos abaixo pressupõem o banco `wordpress` e containers PROD ativos:

```bash
mkdir -p backup
chmod 700 backup
umask 077
lxc exec --project final-equipeN db -- mariadb-dump --single-transaction wordpress > backup/wordpress-prod.sql
lxc exec --project final-equipeN app -- tar -C /var/www/html -czf - . > backup/wordpress-files-prod.tar.gz
```

Mantenha também um backup privado de `conf/tls/`. Uma exportação de arquivos pode incluir senhas; não envie ao repositório público. Coordene uma janela sem alterações para consistência entre banco e uploads.

Teste primeiro em DEV. Crie uma página/publicação e envie uma imagem no WordPress; registre a URL e uma captura. Depois, mantendo as variáveis e a senha do ambiente:

```bash
ENV=dev bash scripts/destroy.sh --dry-run
ENV=dev bash scripts/destroy.sh
ENV=dev bash scripts/deploy.sh
```

Não use `--volumes` nesse teste de persistência. Confira se a mesma publicação e imagem continuam disponíveis e se a CA continua a mesma. Uma alternativa é `deploy.sh --recreate`, que pede confirmação ou aceita `--yes` para a exclusão dos roots, mas nunca apaga volumes.

O teste do zero com `--volumes` deve usar DEV descartável; a avaliação de PROD do zero precisa de backup e acordo da equipe. `latest.tar.gz` e o alias Ubuntu não fixam versões byte a byte: a reprodução aqui é da infraestrutura/serviço, não de artefatos imutáveis.

## Monitoramento e evidências

```bash
ENV=prod bash scripts/monitor.sh --once
ENV=dev bash scripts/monitor.sh --once
ENV=dev bash scripts/test-limits.sh
# Dois terminais para observar a carga, somente em dev-app:
ENV=dev bash scripts/monitor.sh
ENV=dev bash scripts/test-limits.sh --load

# Coleta de leitura; não implanta, não destrói e não gera carga:
ENV=dev IP_SITE=127.0.0.1 bash scripts/registrar-evidencias.sh
ENV=prod IP_SITE=127.0.0.1 bash scripts/registrar-evidencias.sh
```

O coletor salva saídas e códigos de retorno, não inventa aprovação. Não substitui as capturas no navegador ou o registro real de deploy/destroy/reconstrução. Os testes simulados continuam úteis para código, mas não comprovam funcionamento no LXD. O procedimento completo e a coleta de logs estão em [testes-na-vm.md](testes-na-vm.md); a interpretação do painel está em [monitoramento.md](monitoramento.md).

A coluna CPU é tempo acumulado em segundos, não percentual. Os profiles atuais limitam CPU/memória, mas não configuram quota de disco; não há teste OOM. Revise qualquer evidência antes do GitHub e não publique chaves, tokens, `.env` ou `wp-config.php`.

## Validação local do código

Em uma máquina Linux com as dependências disponíveis, a suíte pode ser executada sem instalar ou acessar LXD:

```bash
sudo apt install -y python3-yaml php-cli openssl shellcheck
bash tests/run_local.sh
```

O comando verifica sintaxe Bash/PHP, ShellCheck, o teste PHP existente da Fase 5 e as suítes Python. LXC/curl são simulados em diretórios temporários; a geração/verificação de certificados usa OpenSSL real. Também testa a remoção de campos potencialmente sensíveis dos JSONs coletados. Isso comprova somente o comportamento local do código, não o WordPress, as bridges, os cgroups ou o encaminhamento real da VM.

## Referências

[1]: https://canonical.com/lxd/docs/v5.21/howto/storage_volumes/ "LXD 5.21 — Ciclo de vida e administração de volumes"
[2]: https://canonical.com/lxd/docs/v5.21/reference/manpages/lxc/exec/ "LXD 5.21 — lxc exec e entrada padrão não interativa"
