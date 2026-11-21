# Roteiro de testes reais das fases 7 e 8

Este roteiro deve ser executado na **VM da equipe**, não no Windows/macOS nem no LXC falso dos testes locais. Nenhuma evidência real foi criada por esta revisão. Os testes abaixo preenchem as pendências do texto enviado ao Samuel.

## 1. Atualizar os arquivos sem executar o deploy

Durante a revisão da PR, o responsável da VM pode testar a branch nova antes do merge. Confira que `git status` está limpo antes de trocar de branch:

```bash
cd projeto-final-cloud-computing
git status
git fetch origin
git switch ajustes-samuel-fases-7-8
git pull --ff-only origin ajustes-samuel-fases-7-8
chmod +x scripts/*.sh conf/*.sh
```

Depois que a PR estiver aprovada e incorporada à `dev`, volte à branch compartilhada:

```bash
cd projeto-final-cloud-computing
git status
git switch dev
git pull --ff-only origin dev
chmod +x scripts/*.sh conf/*.sh
```

Se houver alterações locais, pare para preservá-las; não use `reset --hard` ou descarte arquivos. Se `conf/tls/` já existir, faça backup privado dela antes de reconstruir qualquer ambiente.

```bash
lxc remote switch local
lxc info
lxc project show final-equipeN
lxc list --project final-equipeN
ip -br -4 addr
```

Confira o nome do projeto e o IP da interface de rede da VM. O acesso já confirmado em 8081 é WordPress HTTP. O acesso em 8443 é o gerenciamento LXD; não use esse painel como prova do site HTTPS.

## 2. Preparar variáveis e encaminhamentos

```bash
export PROJETO=final-equipeN
export VM_HOST=127.0.0.1
export IP_SITE=127.0.0.1
# EXEMPLO: substitua pelo IPv4 real da VM, mostrado no comando anterior.
export IP_VM=10.0.2.15
read -rsp 'Senha do banco DEV: ' DB_PASS_DEV; echo
export DB_PASS_DEV
```

A senha deve usar letras, números e `_ @ % + = . : , -`. Não cole a senha no GitHub ou no campo de descrição de um commit. Para logs de terminal, informe-a **antes** de iniciar a gravação, sem `bash -x`.
O deploy corrigido transmite a senha aos dois instaladores e à checagem PHP por stdin não interativo, não por argumentos. Atualize os três scripts juntos. Não execute cópias antigas de `/root/config-mariadb.sh` ou `/root/instala-wp.sh` com senha em argv; o próximo deploy envia as versões novas do repositório. Administradores ainda podem inspecionar memória/ambiente e arquivos privados; não apresente essa mudança como sigilo contra root.

No VirtualBox NAT, confira as regras TCP do Windows para a VM: `8081→8081`, `8444→8444`, `8082→8082`, `8445→8445`. A regra `8443→8443`, se já usada para o LXD, é separada e não deve ser substituída. Se usa outro modo de rede, valide o caminho correspondente e firewall.

## 3. Implantar DEV e registrar a execução

Veja o plano primeiro:

```bash
ENV=dev bash scripts/deploy.sh --dry-run
```

Crie uma pasta privada para logs novos:

```bash
mkdir -p docs/evidencias/fases7-8
chmod 700 docs/evidencias/fases7-8
umask 077
RUN="$(date +%Y%m%d-%H%M%S)"
```

Use `script`, disponível no pacote `util-linux` do Ubuntu, para gravar a execução mantendo as confirmações interativas. Não reutilize nomes de logs antigos.

```bash
script -q -e -c 'ENV=dev bash scripts/deploy.sh' "docs/evidencias/fases7-8/${RUN}-deploy-dev.log"
```

Se DEV já existir, o deploy recusa sobrescrevê-lo. Não adicione `--recreate` automaticamente. Primeiro confirme backup e o que será perdido, conforme `docs/automacao.md`.

Se o deploy falhar, preserve o log, leia o erro e corrija o problema antes de prosseguir. Uma saída de erro não pode ser apresentada como implantação aprovada.

## 4. Validar HTTPS e o navegador

O deploy integrado termina executando `fase5-tls.sh`, que usa a CA própria. Confira na VM:

```bash
lxc --project=final-equipeN exec dev-proxy -- nginx -t
lxc --project=final-equipeN config device list dev-proxy
openssl verify -CAfile conf/tls/dev/ca.crt conf/tls/dev/servico.crt
openssl x509 -in conf/tls/dev/servico.crt -noout -ext subjectAltName
curl --fail --head --cacert conf/tls/dev/ca.crt https://127.0.0.1:8445/
```

O dispositivo `porta-https` deve aparecer uma única vez, o SAN deve cobrir o endereço utilizado, e curl deve validar a CA **sem `-k`**. Um redirecionamento para o assistente WordPress em banco novo não significa que o conteúdo do site já foi criado.

Confira também as permissões **depois** da atualização de URLs pela Fase 5:

```bash
lxc --project="$PROJETO" exec dev-app -- stat -c '%U:%G %a %n' /var/www/html/wp-config.php
lxc --project="$PROJETO" exec dev-app -- runuser -u www-data -- test -r /var/www/html/wp-config.php
lxc --project="$PROJETO" exec dev-app -- runuser -u www-data -- test ! -w /var/www/html/wp-config.php
```

Esperado: `root:www-data 640` e código 0 nos dois testes. Eles comprovam acesso de leitura e ausência de escrita direta; não imprima o conteúdo do arquivo, que contém senha. O diretório pai continua gravável pelo servidor, portanto isto não comprova proteção contra remoção/substituição do arquivo. Para uma instalação anterior, o procedimento de correção sem recriar recursos está em `docs/automacao.md`.

Para o navegador no Windows, transfira **somente** `conf/tls/dev/ca.crt`. Antes de confiar na CA, confira sua procedência e compare o fingerprint SHA-256 com o informado pela equipe:

```bash
openssl x509 -in conf/tls/dev/ca.crt -noout -fingerprint -sha256
```

A instalação dessa CA torna certificados assinados por ela confiáveis para o escopo escolhido. Faça isso apenas para a CA conhecida do laboratório. No Windows, o assistente aberto pelo arquivo `.crt` permite instalar no armazenamento do **Usuário Atual**, em **Autoridades de Certificação Raiz Confiáveis**. Não importe `ca.key`, `servico.key`, `.p12` ou `.pfx`. Reabra o navegador e teste `https://127.0.0.1:8445`.

Conclua o assistente WordPress, crie uma publicação e envie uma imagem. Salve captura mostrando URL, site e informação do certificado, sem senhas. Se continuar aparecendo alerta, revise CA instalada, SAN, endereço, validade e encaminhamento; não ignore o alerta para afirmar que o HTTPS foi validado.

## 5. Monitoramento e limites

```bash
ENV=dev bash scripts/monitor.sh --once
ENV=dev bash scripts/test-limits.sh
```

O resultado esperado pelos profiles é 1 CPU por container, memória em torno de 512 MiB em app/proxy e 1 GiB em db, com limite de cgroup correspondente. Se o probe falhar ou mostrar `max`, registre a falha e investigue; não considere o limite comprovado.

Para a carga, abra dois terminais da VM. No primeiro:

```bash
ENV=dev bash scripts/monitor.sh
```

No segundo:

```bash
ENV=dev bash scripts/test-limits.sh --load
```

A carga roda **somente em `dev-app`**, por 20 segundos dentro do container, com proteção adicional no host. Capture o painel antes/durante/depois e descreva o aumento do tempo de CPU. A coluna `u` é acumulada em segundos, não porcentagem. Não gere OOM e não afirme quota de disco: os profiles atuais não configuram esse limite.

## 6. Testar persistência mantendo os volumes

Faça backup do ambiente e guarde a URL da publicação/imagem criada no passo 4. Não use `--volumes` neste teste.

```bash
script -q -e -c 'ENV=dev bash scripts/destroy.sh' "docs/evidencias/fases7-8/${RUN}-destroy-dev-mantem-volumes.log"
script -q -e -c 'ENV=dev bash scripts/deploy.sh' "docs/evidencias/fases7-8/${RUN}-reconstrucao-dev.log"
```

A primeira execução pede a confirmação `final-equipeN/dev` e remove os discos raiz das instâncias. Banco/uploads permanecem. A segunda reconstrói e reaplica a CA existente. Confira que a publicação e a imagem continuam acessíveis e registre a captura após a reconstrução.

Temas/plugins extras e customizações no root não sobrevivem só com os dois volumes: restaure o backup de arquivos quando necessário. A persistência precisa ser observada, não inferida apenas porque os volumes aparecem na lista.

## 7. Testar DEV do zero, apenas se for descartável

Esse passo apaga definitivamente dados DEV. Faça somente se a equipe autorizar e existir backup do que precisa ser mantido.

```bash
ENV=dev bash scripts/destroy.sh --volumes --dry-run
script -q -e -c 'ENV=dev bash scripts/destroy.sh --volumes' "docs/evidencias/fases7-8/${RUN}-destroy-dev-apaga-volumes.log"
script -q -e -c 'ENV=dev bash scripts/deploy.sh' "docs/evidencias/fases7-8/${RUN}-deploy-dev-do-zero.log"
```

Além da confirmação de instâncias, será exigido `APAGAR-VOLUMES:final-equipeN/dev`. Não copie esse procedimento para PROD só para obter um print.

## 8. Validar PROD com uma janela combinada

Como PROD já tem conteúdo, não execute `--recreate` ou `--volumes` sem backup verificado e acordo da equipe. Primeiro faça apenas a coleta e confira o estado atual.

Se PROD ainda está só em HTTP, a validação de TLS pode ser feita com `ENV=prod bash scripts/fase5-tls.sh`, após conferir `IP_VM/IP_SITE`, backup e encaminhamento 8444. Isso muda a URL canônica para HTTPS e deve ser combinado com a equipe. Registre o comando e a resposta do navegador em 8444.

Para provar reconstrução de PROD, use o procedimento de backup/recriação que mantém volumes de `docs/automacao.md`, com gravação de logs e janela de manutenção. Se a avaliação exigir apagar PROD do zero, use cópias privadas verificadas e documente a restauração/preenchimento; não há autorização automática por este roteiro.

## 9. Coletar e publicar evidências revisadas

```bash
ENV=dev IP_SITE=127.0.0.1 bash scripts/registrar-evidencias.sh
ENV=prod IP_SITE=127.0.0.1 bash scripts/registrar-evidencias.sh
unset DB_PASS DB_PASS_DEV DB_PASS_PROD
```

O coletor gera uma pasta nova, registra saídas/códigos de retorno e conserva diagnósticos de falha. Ele não executa deploy/destroy/carga e não configura TLS ou o acesso administrativo. Não substitui os logs/capturas dos passos anteriores.

Antes de enviar ao GitHub, revise cada arquivo: remova/exclua do envio qualquer senha, token, chave, configuração sensível ou informação privada. Identifique data, commit, ambiente e resultado observado. Mantenha as evidências antigas; acrescente as novas em vez de substituí-las.

No relatório, mantenha como **pendente** o que não foi executado. Um teste com LXC/curl simulado, um `--dry-run`, a API/UI em 8443 ou uma resposta curl com `-k` não comprovam os requisitos reais de implantação/HTTPS do WordPress.
