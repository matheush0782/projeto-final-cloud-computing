# Projeto Final — Cloud Computing

## 1. Objetivo

Implementar uma infraestrutura de hospedagem de um site WordPress utilizando Ubuntu 24.04, LXD, containers Linux, Nginx, Apache, PHP e MariaDB.

Este documento mantém o histórico da entrega parcial e acrescenta a integração das fases 7 e 8. As evidências antigas não comprovam a execução dos novos scripts na VM.

Para preparar uma VM nova, atualizar pelo GitHub, implantar e recriar com segurança, consulte [o guia de integração e automação](docs/automacao.md). A interpretação de CPU/memória e os testes de limites estão em [monitoramento](docs/monitoramento.md).

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

Na automação, esse arquivo é um template com `__APP_IP__`, preenchido pelo `deploy.sh`. Inclui também HTTPS com certificado autoassinado gerado dentro do proxy. Não copie o template sem renderização para um Nginx ativo.

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

## 13. Automação de PROD e DEV

A branch Git `dev` armazena o código da equipe; `ENV=dev` seleciona o ambiente de execução. Os mesmos scripts criam PROD (`proxy/app/db`, HTTP 8081, HTTPS 8444) e DEV (`dev-proxy/dev-app/dev-db`, HTTP 8082, HTTPS 8445). DEV usa a rede 10.10.20.0/24 e os volumes separados `dev-vol-db` e `dev-vol-uploads`.

Depois que a equipe adicionar os arquivos no GitHub, atualize o clone na VM:

```bash
git status
git switch dev
git pull --ff-only origin dev
chmod +x scripts/*.sh conf/*.sh
ENV=dev ./scripts/deploy.sh --dry-run
```

O `git pull` não executa scripts. O deploy real exige Bash, LXD local, Python/PyYAML e uma senha informada por `DB_PASS` ou `DB_PASS_PROD`/`DB_PASS_DEV`. O endereço usado no navegador é configurado com `VM_HOST` (padrão 127.0.0.1). Siga os comandos completos do [guia de automação](docs/automacao.md).

`deploy.sh` não exclui instâncias existentes sem `--recreate` e confirmação. `destroy.sh` preserva banco/uploads por padrão; `--volumes` apaga os dois volumes do ambiente e seus dados. Discos raiz e snapshots das instâncias são perdidos mesmo sem `--volumes`, portanto temas/plugins personalizados precisam de backup. Não use `destroy.sh --volumes` no CloudPress atual sem backup verificado.

## 14. Monitoramento e evidências pendentes

```bash
./scripts/monitor.sh --all
ENV=dev ./scripts/monitor.sh --once
ENV=prod ./scripts/test-limits.sh
ENV=dev ./scripts/test-limits.sh --load
```

O teste de carga é opcional, limitado a 20 segundos dentro de `dev-app`. A coluna de CPU mostra segundos acumulados, não percentual. Os profiles atuais limitam CPU/memória, mas não configuram quota de disco.

Os testes em `tests/` validam fluxos com LXC simulado e PHP/cópia com arquivos temporários; não acessam a VM da equipe. Ainda é necessário coletar as evidências reais da reconstrução, PROD/DEV, HTTPS, persistência, painel e limites em `docs/evidencias/`. Não envie senhas, chaves TLS ou backups ao GitHub.
