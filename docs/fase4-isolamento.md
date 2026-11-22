# Fase 4 · Isolamento de Redes e Exposição Controlada

Este documento registra a implementação, automação e validação da **Fase 4** do Projeto Final de Cloud Computing (UNINASSAU), focado na infraestrutura de nuvem privada com LXD/Incus na **Trilha A (WordPress)**.

---

## 1. Objetivos da Fase 4

1. **Garantir a exposição mínima necessária**: apenas o container `proxy` deve receber tráfego vindo de fora da VM (portas 8081 para HTTP e 8444 para HTTPS).
2. **Proteger o banco de dados**: demonstrar e garantir que o MariaDB (`db`, IP `10.10.10.12`, porta 3306) **não** é acessível diretamente fora do host nem a partir de ambientes não autorizados.
3. **Isolar Desenvolvimento e Produção**: comprovar que instâncias em `net-dev` (`10.10.20.0/24`) não conseguem se comunicar com as instâncias em `net-prod` (`10.10.10.0/24`), e vice-versa.
4. **Preservar a conectividade legítima**: garantir que as instâncias continuem com saída para a internet (NAT) e que o proxy reverso continue roteando requisições internas para a aplicação (`10.10.10.11:80`).

---

## 2. Diagnóstico: O Problema do Roteamento Inter-Bridge

### 2.1 Por que duas bridges não são isoladas por padrão?

No Linux, ao criar duas bridges virtuais no mesmo host (`net-prod` em `10.10.10.1/24` e `net-dev` em `10.10.20.1/24`), o kernel do host atua como roteador entre ambas. Uma vez que o encaminhamento IPv4 (`net.ipv4.ip_forward = 1`) fica habilitado para prover saída NAT à internet para os containers, os pacotes trafegam livremente entre as bridges através da tabela de roteamento local do host.

### 2.2 Demonstração da Vulnerabilidade (Fase 4.2)

Ao subir uma instância temporária `teste-dev` na rede `net-dev` e executar uma tentativa de conexão TCP contra a porta 3306 do banco de produção (`10.10.10.12`), o resultado obtido é:

```bash
$ lxc exec teste-dev -- bash -c 'timeout 3 bash -c "echo > /dev/tcp/10.10.10.12/3306" && echo ALCANCOU || echo BLOQUEADO'
ALCANCOU
```

Isso comprova a necessidade de aplicação de regras de firewall de camada de rede (**LXD Network ACLs**) para impor o isolamento.

---

## 3. Arquitetura das ACLs no LXD

O LXD fornece suporte nativo a Network ACLs (implementadas via `nftables` ou Open vSwitch no host). Foram concebidas duas ACLs espelhadas:

```mermaid
flowchart LR
    subgraph Host["Host LXD (VM)"]
        subgraph DEV["Rede net-dev (10.10.20.0/24)"]
            DevC["teste-dev (.15)"]
        end

        subgraph PROD["Rede net-prod (10.10.10.0/24)"]
            Proxy["proxy (.10)"]
            App["app (.11)"]
            DB["db (.12):3306"]
        end

        ACLDev["acl-dev<br/>drop ingress 10.10.10.0/24<br/>drop egress 10.10.10.0/24"]
        ACLProd["acl-prod<br/>drop ingress 10.10.20.0/24<br/>drop egress 10.10.20.0/24"]
    end

    DevC -.->|X BLOQUEADO| DB
    Proxy -->|Permitido| App
    App -->|Permitido| DB
```

### 3.1 Regras de acl-prod e acl-dev

- **`acl-prod`**:
  - `ingress`: `action=drop source=10.10.20.0/24` (descarta tráfego vindo de DEV)
  - `egress`: `action=drop destination=10.10.20.0/24` (descarta tráfego enviado para DEV)
- **`acl-dev`**:
  - `ingress`: `action=drop source=10.10.10.0/24` (descarta tráfego vindo de PROD)
  - `egress`: `action=drop destination=10.10.10.0/24` (descarta tráfego enviado para PROD)

### 3.2 A Importância de `security.acls.default.*.action=allow`

> [!IMPORTANT]
> No LXD, quando uma ACL é vinculada a uma bridge de rede, o comportamento padrão para qualquer pacote que **não coincida com uma regra explícita** passa a ser **REJEITAR/DROP**.
> Se as diretivas `security.acls.default.ingress.action=allow` e `security.acls.default.egress.action=allow` não forem configuradas, as instâncias perderão imediatamente o acesso ao gateway da bridge, à resolução DNS e ao NAT de saída para a internet.

---

## 4. Arquivos de Configuração das ACLs

Os arquivos versionados residem no diretório `conf/`:

### 4.1 `conf/acl-prod.yaml`
```yaml
name: acl-prod
description: ACL para isolamento da rede net-prod contra net-dev
rules:
  - action: drop
    direction: ingress
    source: 10.10.20.0/24
    state: enabled
  - action: drop
    direction: egress
    destination: 10.10.20.0/24
    state: enabled
config: {}
used_by:
  - /1.0/networks/net-prod
```

### 4.2 `conf/acl-dev.yaml`
```yaml
name: acl-dev
description: ACL para isolamento da rede net-dev contra net-prod
rules:
  - action: drop
    direction: ingress
    source: 10.10.10.0/24
    state: enabled
  - action: drop
    direction: egress
    destination: 10.10.10.0/24
    state: enabled
config: {}
used_by:
  - /1.0/networks/net-dev
```

### 4.3 Saída de `lxc network acl show acl-prod` (Exigido pelo Roteiro)

```yaml
$ lxc network acl show acl-prod
name: acl-prod
description: ACL para isolamento da rede net-prod contra net-dev
rules:
- action: drop
  direction: ingress
  source: 10.10.20.0/24
  state: enabled
- action: drop
  direction: egress
  destination: 10.10.20.0/24
  state: enabled
config: {}
used_by:
- /1.0/networks/net-prod
```

---

## 5. Script de Automação (`scripts/fase4-acls.sh`)

O script `scripts/fase4-acls.sh` automatiza todo o ciclo de vida das ACLs de forma idempotente, sem duplicar regras e integrando-se aos padrões de projeto do repositório.

### 5.1 Modos de Execução

| Parâmetro | Finalidade |
|---|---|
| `./scripts/fase4-acls.sh --apply` | Aplica as regras de isolamento e associa às redes (padrão se omitido). |
| `./scripts/fase4-acls.sh --status` | Inspeciona ACLs, regras e configurações ativas em `net-prod` e `net-dev`. |
| `./scripts/fase4-acls.sh --dry-run` | Simula as ações sem efetuar qualquer modificação no LXD. |
| `./scripts/fase4-acls.sh --test` | Cria container de teste em `net-dev`, valida bloqueio ao banco, testa saída internet e verifica WordPress. |
| `./scripts/fase4-acls.sh --rollback` | Remove a associação das redes e exclui as ACLs com segurança. |

### 5.2 Exemplo de Execução do Script

```bash
# Simular antes de aplicar
bash scripts/fase4-acls.sh --dry-run

# Aplicar as ACLs
bash scripts/fase4-acls.sh --apply

# Conferir o status
bash scripts/fase4-acls.sh --status

# Executar a bateria de testes automatizados
bash scripts/fase4-acls.sh --test
```

---

## 6. Comparação dos Testes: Antes x Depois das ACLs

Conforme exigido pelo Roteiro de Implementação da disciplina, a tabela abaixo sintetiza os resultados comprovando a eficácia das regras:

| Cenário de Teste | Antes das ACLs (Fase 4.2) | Depois das ACLs (Fase 4.4) | Avaliação |
|---|---|---|---|
| **Conexão TCP DEV → Banco PROD** (`10.10.10.12:3306`) | **`ALCANCOU`** | **`BLOQUEADO`** | **Conforme** (Isolamento ativo) |
| **Ping ICMP DEV → Banco PROD** (`10.10.10.12`) | 0% perda (time=0.072ms) | 100% packet loss (timeout) | **Conforme** (Pacotes descartados) |
| **Saída da Aplicação para Internet** (`deb.debian.org`) | `HTTP/2 200` | `HTTP/2 200` | **Conforme** (NAT preservado) |
| **Acesso Externo ao WordPress** (porta `8081` / `8444`) | `HTTP/1.1 200 OK` | `HTTP/1.1 200 OK` | **Conforme** (Proxy operacional) |
| **Conexão Interna Proxy → App** (`10.10.10.11`) | `HTTP/1.1 200 OK` | `HTTP/1.1 200 OK` | **Conforme** (Comunicação local mantida) |
| **Exposição Externa da Porta 3306** (Notebook) | `TcpTestSucceeded : False` | `TcpTestSucceeded : False` | **Conforme** (Banco fechado de fora) |

---

## 7. Validação de Exposição de Portas (Fase 4.1)

Apenas o container `proxy` deve ser publicado para o exterior.

### 7.1 Verificação dos Dispositivos LXD
```bash
$ lxc config device list proxy
eth0
porta-http
porta-https
root

$ lxc config device list db
dados
eth0
root
```
*Comprovação: A instância `db` possui apenas dispositivos `disk` e `nic`; não há dispositivo `proxy` cadastrado.*

### 7.2 Teste do Notebook do Aluno (PowerShell no Windows)
```powershell
# Porta 8081 (HTTP WordPress): DEVE RESPONDER TRUE
Test-NetConnection <IP-DA-VM> -Port 8081
# TcpTestSucceeded : True

# Porta 8444 (HTTPS WordPress): DEVE RESPONDER TRUE
Test-NetConnection <IP-DA-VM> -Port 8444
# TcpTestSucceeded : True

# Porta 3306 (MariaDB): DEVE RESPONDER FALSE
Test-NetConnection <IP-DA-VM> -Port 3306
# TcpTestSucceeded : False
```

---

## 8. Procedimento de Restauração / Rollback

Caso seja necessário remover as ACLs para manutenção ou diagnóstico temporário:

```bash
bash scripts/fase4-acls.sh --rollback
```

Ou manualmente via comandos LXD:

```bash
# 1. Desvincular das redes
lxc network unset net-prod security.acls
lxc network unset net-prod security.acls.default.ingress.action
lxc network unset net-prod security.acls.default.egress.action

lxc network unset net-dev security.acls
lxc network unset net-dev security.acls.default.ingress.action
lxc network unset net-dev security.acls.default.egress.action

# 2. Excluir as ACLs
lxc network acl delete acl-prod
lxc network acl delete acl-dev
```

---

## 9. Evidências Coletadas

Os registros de terminal completos estão organizados na pasta `docs/evidencias/fase4/`:

1. [01-estado-inicial.txt](file:///c:/Users/Usuario/Desktop/Faculdade/projeto-final-cloud-computing/docs/evidencias/fase4/01-estado-inicial.txt): Estado das redes, instâncias e portas antes da alteração.
2. [02-teste-antes-acl.txt](file:///c:/Users/Usuario/Desktop/Faculdade/projeto-final-cloud-computing/docs/evidencias/fase4/02-teste-antes-acl.txt): Teste demonstrando o problema de isolamento (`ALCANCOU`).
3. [03-acls-aplicadas.txt](file:///c:/Users/Usuario/Desktop/Faculdade/projeto-final-cloud-computing/docs/evidencias/fase4/03-acls-aplicadas.txt): Criação das regras e saída integral de `lxc network acl show acl-prod`.
4. [04-teste-depois-acl.txt](file:///c:/Users/Usuario/Desktop/Faculdade/projeto-final-cloud-computing/docs/evidencias/fase4/04-teste-depois-acl.txt): Teste confirmando o bloqueio (`BLOQUEADO`), comparação lado a lado e saída para internet.
5. [05-validacao-servico.txt](file:///c:/Users/Usuario/Desktop/Faculdade/projeto-final-cloud-computing/docs/evidencias/fase4/05-validacao-servico.txt): Validação do WordPress no proxy e testes das portas externas via PowerShell e Linux.
