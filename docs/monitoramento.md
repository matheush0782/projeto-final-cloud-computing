# Monitoramento e teste de limites LXD

Este documento descreve `scripts/monitor.sh` e `scripts/test-limits.sh`. Os dois scripts carregam `scripts/common.sh` por um caminho absoluto derivado de `BASH_SOURCE`, chamam `carregar_config` e usam `lx()`. Portanto, cada consulta fica sob `--project="$PROJETO"`; nenhum dos scripts usa o projeto `default` nem `--all-projects`.

## Configuração e contrato compartilhado

Os padrões são `ENV=prod` e `PROJETO=final-equipeN`. `POOL` mantém o padrão `pool-final`. `carregar_config` valida `ENV` e expande os seguintes valores:

- `prod`: `PREFIXO=''`, `REDE=net-prod`, `SUBNET=10.10.10`, portas `8081` e `8444`;
- `dev`: `PREFIXO=dev-`, `REDE=net-dev`, `SUBNET=10.10.20`, portas `8082` e `8445`.

Qualquer outro valor de `ENV` falha antes de consultar LXD. A mesma função monta os arrays Bash `INSTANCIAS` (`proxy`, `app`, `db`, com o prefixo do ambiente) e `VOLUMES` (`vol-db` e `vol-uploads`, com o prefixo). Os scripts usam `INSTANCIAS` como allowlist; não fazem descoberta fora do projeto selecionado.

O contrato esperado de `common.sh` também inclui `exigir_comandos`, `checar_lxd`, `lx`, `log` e `falhar`. `checar_lxd` verifica `lxc`, o remoto padrão `local` e a resposta do servidor. A inicialização é deliberadamente feita somente depois do parsing de `--env`, para que `--env dev` seja aplicado ao `carregar_config`.

## `monitor.sh`

A sintaxe é:

```text
scripts/monitor.sh [--once] [--interval N] [--env prod|dev] [--all]
scripts/monitor.sh help
```

Sem `--once`, o monitor repete a amostra a cada cinco segundos. `--interval N` exige um inteiro positivo. `--once` é a forma recomendada para uma evidência ou para uma verificação manual. Exemplos:

```bash
ENV=prod PROJETO=final-equipeN scripts/monitor.sh --once
scripts/monitor.sh --once --env dev
scripts/monitor.sh --interval 10 --env prod
scripts/monitor.sh --once --all
```

Sem `--all`, o script forma uma expressão regular ancorada, como `^(proxy|app|db)$` ou `^(dev-proxy|dev-app|dev-db)$`, e a envia ao `lxc list`. Isso evita que `app` selecione `app-extra`. Com `--all`, a filtragem por nomes esperados é removida, mas a consulta continua no projeto definido por `PROJETO`; instâncias de outros projetos não entram.

A listagem usa `lxc list -c ns4mDu --format=csv`, através de `lx()`, e exibe nome, estado, IPv4, memória, disco e CPU, conforme os shorthands documentados pelo LXD [2]. As colunas significam:

- `n`: nome;
- `s`: estado;
- `4`: IPv4;
- `m`: uso de memória;
- `D`: uso de disco;
- `u`: uso acumulado de CPU em segundos, **não** percentual.

Assim, o valor de `u` não deve ser lido como “CPU em 40%”. Para uma porcentagem seria necessário comparar duas amostras e considerar o intervalo, a quantidade de CPUs e o tempo de CPU. A listagem já é a fonte principal para estado, CPU, memória e disco. Para cada `app`, `db` ou `proxy` selecionado e em `RUNNING`, há ainda uma consulta interna limitada a cinco segundos com `df -hP /`. O script também informa `/var/www/html/wp-content/uploads` e `/var/lib/mysql` quando esses caminhos existem. Falha de um `df` interno gera aviso; falha da listagem principal encerra com erro, pois não seria honesto apresentar uma amostra incompleta como atual.

### Métricas Prometheus

Depois da listagem, o monitor tenta:

```bash
lxc --project="$PROJETO" query "/1.0/metrics?project=$PROJETO"
```

A documentação oficial do LXD descreve `/1.0/metrics` como o endpoint Prometheus e mostra que o parâmetro `project` restringe a coleta a um ou mais projetos; as amostras também carregam os rótulos `name` e `project` [1]. O script mantém o parâmetro explícito mesmo já usando `--project` no cliente. Ele aceita que o endpoint não esteja disponível: nesse caso registra um aviso e continua com a listagem. Não habilita `core.metrics_address`, não expõe uma API nova e não trata a ausência de métricas como falha do monitor.

A resposta é filtrada sem `grep | head`: exibe até 12 amostras de `lxd_cpu_seconds_total`, `lxd_memory_MemAvailable_bytes` e `lxd_filesystem_avail_bytes`, com `project="$PROJETO"` e `name` na listagem atual. Sem `--all`, os nomes estão na allowlist do ambiente; com `--all`, podem pertencer a ambos os ambientes, sempre dentro do projeto. Se existir um rótulo `env` ou `environment`, ele também precisa corresponder a `ENV`. Essas métricas ficam em cache por oito segundos [1], portanto reduzir `--interval` abaixo disso não implica uma nova medição no daemon.

## `test-limits.sh`

A sintaxe é:

```text
scripts/test-limits.sh [--env prod|dev] [--load]
scripts/test-limits.sh help
```

O script testa somente as três instâncias de `INSTANCIAS` no projeto. Para cada uma, consulta `lxc --project="$PROJETO" query "/1.0/instances/INSTANCE?project=$PROJETO"` e extrai o `expanded_config` da resposta JSON (direta ou dentro de `metadata`); não usa `config show --format=json`, opção que não faz parte do contrato documentado do LXD 5.21 [3]. Depois consulta o estado e exige `RUNNING` antes de executar comandos no guest. O teste não instala pacotes, não escreve dados persistentes e não aloca memória deliberadamente.

A configuração expandida é convertida da seguinte forma:

- `limits.cpu=1` significa uma CPU; formas de conjunto como `0-1` e `0,2` são contadas pelos itens/ranges;
- `nproc` dentro do guest deve ser igual à contagem esperada;
- `free -m` é consultado dentro do guest e o total de memória deve ficar próximo de `limits.memory`, com tolerância de 15% e piso de 1 MiB. A tolerância é intencional: arredondamento, overhead do kernel e diferenças do runtime tornam inadequado exigir igualdade textual;
- em cgroup v2, o limite é lido de `/sys/fs/cgroup/memory.max`; em cgroup v1, usa-se `/sys/fs/cgroup/memory/memory.limit_in_bytes`. O valor deve ser numérico e ficar a no máximo 1 MiB de `limits.memory`, evitando esconder divergências com uma margem ampla;
- em cgroup v2, a CPU é contada em `cpuset.cpus.effective` (com fallback para `cpuset.cpus`); em v1, em `cpuset/cpuset.cpus`. A contagem deve coincidir com `limits.cpu`.

Uma instância parada, um limite ausente, `memory.max=max`, um cgroup não identificável ou uma divergência de `nproc`, memória ou cpuset fazem o teste terminar com falha. Isso diferencia “não foi possível provar o limite” de “o limite está correto”. Os probes comuns expiram em cinco segundos.

### Carga opcional de CPU

`--load` só é aceito com `--env dev`. A opção é deliberada e deve ser executada apenas depois de revisar a configuração. Ela roda **uma única vez em `dev-app`**, com `timeout 30s` no host envolvendo `lxc --project="$PROJETO" exec dev-app -- timeout 20s sh -c 'yes > /dev/null'`. O `timeout 20s` do guest encerra a carga sozinha; o loop não fica infinito dentro do guest. O código de retorno `124` é o resultado esperado; qualquer outro código é reportado como falha. Não há teste de alocação que possa provocar OOM.

Exemplos seguros para o roteiro:

```bash
scripts/test-limits.sh --env dev
scripts/test-limits.sh --env dev --load
```

Para produção, use apenas a verificação sem carga:

```bash
scripts/test-limits.sh --env prod
```

## Validação local e pendências da VM

A validação local não executa LXC real. A sintaxe pode ser conferida arquivo a arquivo, e a suíte usa um cliente LXC falso:

```bash
for arquivo in scripts/*.sh conf/*.sh; do bash -n "$arquivo" || exit 1; done
python3 tests/test_scripts.py
```

Ainda é necessária a evidência na VM com o daemon e os containers reais. Antes de registrar o resultado, deve-se executar `scripts/monitor.sh --once --env prod` e, quando o ambiente de desenvolvimento estiver criado e em execução, `scripts/test-limits.sh --env dev`; a evidência deve conservar a saída do projeto selecionado, incluindo o retorno do endpoint de métricas ou o aviso de indisponibilidade. Também permanece pendente comprovar, na VM, `nproc`, `free -m`, o limite do cgroup v2 ou v1 e a contagem de cpuset para cada instância. A carga `--load` deve ficar restrita a `dev-app` no ambiente dev, com guard de 30 s no host, timeout de 20 s no guest e `124` esperado.

Os arquivos históricos em `docs/evidencias/` não são tratados por estes scripts como prova de uma execução atual. Não foram executados comandos LXC reais durante a validação local desta entrega.

## Referências

[1]: https://canonical.com/lxd/docs/default/metrics/ "LXD — How to monitor metrics"

[2]: https://documentation.ubuntu.com/lxd/stable-5.21/reference/manpages/lxc/list/ "LXD 5.21 — lxc list"

[3]: https://canonical.com/lxd/docs/default/reference/manpages/lxc/config/show/ "LXD — lxc config show"
