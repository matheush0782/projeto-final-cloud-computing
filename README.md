# Projeto Final — Cloud Computing

Projeto acadêmico de implementação de uma infraestrutura de hospedagem em nuvem privada, utilizando **Ubuntu 24.04, LXD e containers Linux**. A aplicação escolhida para a trilha é o **WordPress**, publicado por meio de um proxy reverso Nginx e conectado a um banco de dados MariaDB.

O repositório reúne os arquivos de configuração, profiles, scripts de automação, testes e documentação utilizados na construção e validação do ambiente.

## Objetivos

- Provisionar e administrar uma infraestrutura de containers com LXD.
- Separar os ambientes de produção (PROD) e desenvolvimento (DEV).
- Hospedar o WordPress com Nginx, Apache, PHP e MariaDB.
- Controlar a comunicação entre redes e a exposição de serviços.
- Implementar mecanismos de snapshots, backup e restauração.
- Automatizar implantação, monitoramento e coleta de evidências.

## Tecnologias

| Tecnologia | Utilização |
|---|---|
| Ubuntu 24.04 LTS | Sistema operacional da máquina virtual |
| VirtualBox | Virtualização do ambiente |
| LXD 5.21.7 LTS | Gerenciamento de containers, redes e armazenamento |
| Nginx | Proxy reverso |
| Apache | Servidor web da aplicação |
| PHP | Execução do WordPress |
| WordPress | Aplicação hospedada |
| MariaDB | Banco de dados |
| Bash e Python | Automação e testes |
| GitHub Actions | Validação automatizada do repositório |

## Arquitetura

A infraestrutura é dividida em dois ambientes isolados, PROD e DEV. Cada ambiente possui um proxy reverso, uma aplicação WordPress e um banco de dados.

### Produção (PROD)

| Container | Função | Endereço |
|---|---|---|
| `proxy` | Nginx — proxy reverso | `10.10.10.10` |
| `app` | Apache, PHP e WordPress | `10.10.10.11` |
| `db` | MariaDB | `10.10.10.12` |

### Desenvolvimento (DEV)

| Container | Função | Endereço |
|---|---|---|
| `dev-proxy` | Nginx — proxy reverso | `10.10.20.10` |
| `dev-app` | Apache, PHP e WordPress | `10.10.20.11` |
| `dev-db` | MariaDB | `10.10.20.12` |

### Redes e portas

| Recurso | Configuração |
|---|---|
| Rede PROD | `net-prod` — `10.10.10.0/24` |
| Rede DEV | `net-dev` — `10.10.20.0/24` |
| HTTP PROD | `8081` |
| HTTPS PROD | `8444` |
| HTTP DEV | `8082` |
| HTTPS DEV | `8445` |
| API/UI do LXD | `8443` |

A porta `8443` é destinada ao gerenciamento do LXD e não representa o HTTPS do WordPress. O banco de dados utiliza a porta interna `3306` e não deve ser exposto diretamente ao host ou à rede externa.

O fluxo de acesso da aplicação é:

1. O usuário acessa a porta HTTP ou HTTPS do ambiente.
2. O Nginx recebe a requisição no container de proxy.
3. O proxy encaminha a requisição para o container da aplicação.
4. O WordPress acessa o MariaDB pela rede interna do respectivo ambiente.

## Profiles e armazenamento

O projeto utiliza quatro profiles LXD:

- **perfil-base:** configura recursos, rede e disco raiz.
- **perfil-proxy:** configura Nginx e OpenSSL.
- **perfil-app:** configura Apache, PHP e extensões necessárias ao WordPress.
- **perfil-db:** configura MariaDB e seus limites de recursos.

O pool de armazenamento utilizado é `pool-final`, com driver `dir`. Os volumes personalizados separam os dados persistentes do ciclo de vida dos containers:

| Volume | Utilização |
|---|---|
| `vol-db` | Dados do MariaDB em PROD |
| `vol-uploads` | Arquivos enviados ao WordPress em PROD |
| `dev-vol-db` | Dados do MariaDB em DEV |
| `dev-vol-uploads` | Arquivos enviados ao WordPress em DEV |

Snapshots de instâncias não incluem volumes personalizados. Por isso, os procedimentos de proteção de dados precisam considerar os dois recursos.

## Segurança e isolamento

O projeto utiliza Network ACLs do LXD para controlar o tráfego entre `net-prod` e `net-dev`. As regras `acl-prod` e `acl-dev` bloqueiam a comunicação entre as sub-redes, preservando o tráfego necessário dentro de cada ambiente.

Outras medidas previstas na implementação:

- Exposição dos serviços web por meio dos proxies reversos.
- Banco de dados sem publicação direta de porta externa.
- Configuração de HTTPS com uma autoridade certificadora própria.
- Separação de dados persistentes em volumes personalizados.
- Proteção de credenciais e materiais privados fora do repositório.
- Cuidados específicos nos procedimentos de remoção e recriação de containers.

## Organização do repositório

| Diretório/arquivo | Conteúdo |
|---|---|
| `conf/` | Configurações de serviços, redes, ACLs e TLS |
| `profiles/` | Profiles utilizados pelas instâncias LXD |
| `networks/` | Definições das redes PROD e DEV |
| `scripts/` | Scripts de implantação, segurança, backup, restauração e monitoramento |
| `tests/` | Testes automatizados e mocks |
| `docs/` | Documentação técnica, procedimentos e evidências |
| `.github/workflows/` | Fluxos de validação automatizada |

## Automação e testes

Os scripts em `scripts/` automatizam tarefas da infraestrutura, incluindo:

- Implantação e remoção controlada dos ambientes.
- Configuração e validação das ACLs.
- Configuração de TLS.
- Criação de snapshots e backups.
- Restauração de instâncias e volumes.
- Limpeza de snapshots antigos.
- Monitoramento de recursos e verificação de limites.
- Registro de evidências.

Para executar a suíte de validação local, em um ambiente Linux com as dependências descritas na documentação:

```bash
bash tests/run_local.sh
```

Os testes locais utilizam mocks para comandos LXD e ferramentas de rede quando apropriado. Portanto, um teste automatizado aprovado não substitui a validação dos serviços e recursos em uma VM com LXD real.

## Documentação

- [Isolamento de redes e ACLs — Fase 4](docs/fase4-isolamento.md)
- [Guia de snapshots, backup, restauração e limpeza — Fase 6](docs/README.md)
- [Validação e auditoria da Fase 6](docs/fase-6/README.md)
- [Automação e procedimentos de implantação](docs/automacao.md)
- [Testes e validações na VM](docs/testes-na-vm.md)
- [Validação local do código](docs/validacao-local.md)
- [Monitoramento e teste de limites](docs/monitoramento.md)
- [Evidências da implementação](docs/evidencias/)

## Estado das validações

A documentação registra a aprovação de **45 testes automatizados locais**, além de verificações de sintaxe, lint e testes locais relacionados à Fase 5. Esses resultados validam partes do código e da automação, mas não comprovam, por si só, o funcionamento de uma implantação em um daemon LXD real.

As validações de infraestrutura devem ser registradas separadamente, incluindo implantação dos ambientes, isolamento efetivo das redes, acesso HTTP/HTTPS, persistência após recriação, limites de recursos e monitoramento. Consulte os documentos de cada fase para identificar os procedimentos e as pendências correspondentes.

## Cuidados importantes

- Confirme o projeto LXD selecionado antes de executar scripts. Os scripts utilizam o projeto configurado, cujo padrão documentado é `final-equipeN`; ajuste a variável correspondente caso o nome real do projeto seja diferente.
- Faça e verifique backups antes de operações que possam afetar dados.
- Teste procedimentos de recriação e restauração primeiro no ambiente DEV.
- A opção `--volumes` em procedimentos de remoção pode apagar dados persistentes. Não a utilize em PROD sem backup verificado e autorização da equipe.
- Não envie ao GitHub senhas, tokens, chaves privadas, arquivos `.env`, `wp-config.php` ou backups com dados da aplicação.

---

Projeto desenvolvido como atividade acadêmica da disciplina de **Cloud Computing — UNINASSAU**.
