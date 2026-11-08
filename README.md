# Projeto Final — Cloud Computing

## 1. Objetivo

Implementar uma infraestrutura de hospedagem de um site WordPress utilizando Ubuntu 24.04, LXD, containers Linux, Nginx, Apache, PHP e MariaDB.

Este documento registra o estado atual da implementação e as atividades realizadas até a entrega parcial.

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
