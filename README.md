# Projeto Final — Cloud Computing

## 1. Objetivo

Implementar uma infraestrutura de hospedagem de um site WordPress utilizando Ubuntu 24.04, LXD, containers Linux, Nginx, Apache, PHP e MariaDB.

Este documento preserva o histórico da entrega parcial e registra a integração dos scripts do Samuel com a Fase 5 já presente na `dev`. As saídas antigas não comprovam execução dos scripts novos.

Consulte [automação integrada](docs/automacao.md), [testes reais na VM](docs/testes-na-vm.md) e [monitoramento](docs/monitoramento.md) antes de implantar ou recriar recursos.

## 2. Ambiente utilizado

- Sistema operacional: Ubuntu 24.04
- Virtualização: VirtualBox
- Gerenciador de containers: LXD 5.21.7 LTS
- Armazenamento LXD: pool-final
- Driver de armazenamento: dir
- Projeto LXD: final-equipeN

## 3. Arquitetura

A infraestrutura utiliza três containers principais:

| Container | Função | Endereço IP |
|---|---|---|
| proxy | Nginx — proxy reverso | 10.10.10.10 |
| app | Apache, PHP e WordPress | 10.10.10.11 |
| db | MariaDB | 10.10.10.12 |

O fluxo de acesso é:

1. O usuário acessa o serviço pela porta 8081.
2. O Nginx recebe a requisição no container proxy.
3. O Nginx encaminha a requisição para o container app.
4. O WordPress utiliza o MariaDB no container db.

## 4. Redes

Foram criadas duas redes:

- net-prod: 10.10.10.0/24 — utilizada pelos containers da aplicação.
- net-dev: 10.10.20.0/24 — criada para o ambiente de desenvolvimento.

A rede net-prod está associada aos containers proxy, app e db.

## 5. Profiles LXD

Foram criados quatro profiles:

- perfil-base: configura recursos, rede e disco raiz.
- perfil-proxy: instala Nginx e OpenSSL.
- perfil-app: instala Apache, PHP e extensões necessárias ao WordPress.
- perfil-db: instala MariaDB e define limite de memória de 1 GiB.

O perfil-base define limite de 1 CPU e 512 MiB de memória. Os demais profiles complementam essa configuração.

## 6. Armazenamento e persistência

Foi criado o pool de armazenamento pool-final, utilizando o driver dir.

Foram criados dois volumes:

- vol-db: utilizado para armazenar os dados do MariaDB.
- vol-uploads: montado no diretório /var/www/html/wp-content/uploads do container app.

Esses volumes foram associados aos respectivos containers para separar os dados persistentes do ciclo de vida das instâncias.

O teste formal de persistência por exclusão e recriação dos containers ainda está pendente.

## 7. WordPress

O WordPress foi instalado no container app, utilizando Apache e PHP.

O banco de dados utilizado é MariaDB, hospedado no container db.

O site foi configurado com o título CloudPress e recebeu uma publicação intitulada:

"Computação em Nuvem: Transformando o Mundo Digital"

A publicação contém texto explicativo e uma imagem relacionada à computação em nuvem.

O acesso local é realizado pelo endereço:

http://127.0.0.1:8081

A porta 8081 da máquina virtual é encaminhada para a porta 8081 do computador hospedeiro por meio de uma regra de encaminhamento de portas do VirtualBox.

## 8. Proxy reverso

O container proxy utiliza Nginx para receber as requisições HTTP e encaminhá-las ao container app, no endereço 10.10.10.11.

A configuração está armazenada em:

conf/nginx-servico.conf

## 9. Backups

Foram gerados backups locais:

- backup/wordpress.sql: exportação do banco de dados.
- backup/wordpress-files.tar.gz: cópia dos arquivos do WordPress.

Os arquivos foram verificados e a pasta backup está incluída no .gitignore, pois contém informações sensíveis.

Os backups não devem ser enviados ao repositório público.

## 10. Evidências

As evidências da implementação estão armazenadas em:

docs/evidencias/

Entre os registros estão:

- Informações do ambiente virtual.
- Recursos de memória e armazenamento.
- Redes e pool de armazenamento.
- Lista dos containers.
- Capturas de tela do WordPress e da publicação.

## 11. Limitações e atividades pendentes

- O suporte a KVM não estava disponível no ambiente, devido à ausência de /dev/kvm. A limitação foi identificada e documentada.
- A infraestrutura WordPress está funcionando e foi verificada após reinicializações da máquina virtual.
- Ainda é necessário realizar o teste formal de persistência dos volumes, recriando os containers db e app conforme o roteiro do projeto.
- As demais fases do projeto serão realizadas conforme o cronograma da disciplina.

## 12. Observação

Este README representa o estado parcial da implementação. Ele não indica que todas as etapas do projeto final foram concluídas.

## 13. Integração do Samuel com a Fase 5

A revisão parte da `dev` no commit `8145908`, após a incorporação da Fase 5 pela PR #3. A automação da PR #1 foi reaproveitada sem `.DS_Store` e sem excluir as evidências anteriores. Os arquivos de acesso/TLS da equipe foram preservados.

O deploy não gera mais um certificado de serviço autoassinado separado. Ele usa a CA própria e `scripts/fase5-tls.sh` como estratégia única de TLS, com os caminhos `/etc/nginx/ssl/servico.crt` e `/etc/nginx/ssl/servico.key`. Os materiais em `conf/tls/prod/` e `conf/tls/dev/` são locais, privados e ignorados pelo Git.

`fase5-tls.sh` atualiza as URLs WordPress com PHP, ativa a configuração Nginx e verifica/atualiza `porta-https` sem duplicá-lo. Na recriação, reaplica os certificados da CA existente. O deploy exige `IP_VM` real e `IP_SITE` válido para esse fluxo; `--http-only` é a alternativa explícita para manter apenas HTTP enquanto a equipe valida TLS.

## 14. Portas e remoção segura

PROD: HTTP **8081**, HTTPS do WordPress **8444**. DEV: HTTP **8082**, HTTPS do WordPress **8445**. A porta **8443** pertence exclusivamente à API/UI do LXD, não é evidência de HTTPS WordPress. Depois da ativação TLS, HTTP redireciona para a porta HTTPS do ambiente.

`destroy.sh` e `deploy.sh --recreate` removem containers, discos raiz e snapshots das instâncias, mantendo banco/uploads em volumes personalizados por padrão. Temas/plugins personalizados no root precisam de backup. `destroy.sh --volumes` também apaga os volumes e seus dados, exigindo uma confirmação adicional: `--yes` sozinho não autoriza essa exclusão.

```bash
ENV=dev bash scripts/deploy.sh --dry-run
ENV=dev bash scripts/destroy.sh --volumes --dry-run
```

Esses planos não consultam nem alteram o LXD. Não execute a exclusão de volumes de PROD sem backup verificado e acordo da equipe.

## 15. Validação e evidências pendentes

```bash
ENV=dev bash scripts/monitor.sh --once
ENV=dev bash scripts/test-limits.sh
ENV=dev bash scripts/test-limits.sh --load
ENV=dev IP_SITE=127.0.0.1 bash scripts/registrar-evidencias.sh
```

A carga é opcional, limitada a 20 segundos dentro de `dev-app`. O coletor só lê informações e registra resultados; não executa deploy, destroy ou carga. Não substitui logs da reconstrução, o teste de persistência e prints do navegador.

Testes locais em `tests/` verificam código com LXC/curl simulados e fixtures PHP/OpenSSL; não equivalem a testes na VM. A validação real de PROD/DEV, HTTPS com CA confiável, reconstrução, limites e monitoramento ainda precisa ser realizada e registrada pela equipe. Não publique chaves privadas, senhas, tokens ou backups nas evidências.

## 16. Correção de segurança da PR #4

O instalador configura `wp-config.php` como **`root:www-data`, modo `0640`**: Apache/PHP lê pelo grupo, sem escrita direta no arquivo. A Fase 5 preserva essas permissões ao alterar URLs. Isso não impede substituição via diretório pai, que continua com o comportamento de propriedade existente.

O deploy agora transmite a senha por stdin não interativo para MariaDB, WordPress e a checagem PHP, sem colocá-la em argv. Os dois instaladores exigem `--password-stdin`; atualize os três scripts juntos. Senhas lidas com `read -rsp` continuam compatíveis com `DB_PASS` e com os fallbacks PROD/DEV. A limpeza de temporários e os limites desta proteção estão em [automação](docs/automacao.md).

Fazer `git pull` não corrige automaticamente o arquivo de uma instalação existente. Use o procedimento de proprietário/modo da documentação, após backup e confirmação do destino, sem apagar/recriar containers apenas para isso.

A suíte local passou com **45 testes Python, sem falhas, erros ou skips**, além de Bash/PHP/ShellCheck e do teste local da Fase 5. As permissões foram verificadas em arquivos temporários reais; LXD/curl continuam simulados. Veja [validação local](docs/validacao-local.md). Os testes na VM/navegador permanecem pendentes.
