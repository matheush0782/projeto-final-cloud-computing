# Validação local da revisão do Samuel

## Correção de segurança da PR #4 — resultado atual

Em **21/11/2026**, a correção incremental foi preparada sobre o head publicado da PR #4: `1135bfa1eb9f9c5c09b1dff3309456363f2c8f22`, branch `ajustes-samuel-fases-7-8`. A PR estava aberta, com destino `dev`. Nenhum commit, push, merge, deploy ou destroy real foi executado nesta revisão.

Após corrigir proprietário/permissões e o transporte da senha, foram revisados os contratos `common.sh`/deploy/Fase 5 e ampliados os testes, preservando os anteriores. O teste de permissões executa o bloco real do instalador em um docroot temporário, em vez de apenas reproduzir comandos de chown inventados no teste. Os testes de transporte verificam também formato/quantidade de argumentos, a opção não interativa e ausência de valores redigidos que poderiam esconder uma regressão.

O comando final `bash tests/run_local.sh` terminou com **código 0**:

```text
Ran 45 tests in 215.571s

OK
Validações locais concluídas. Testes reais no LXD/navegador continuam pendentes.
```

Resultado: **45 testes aprovados; 0 falhas, 0 erros e 0 skips**. Também passaram sintaxe Bash, lint PHP, ShellCheck dos scripts de automação/instaladores e `tests/test_fase5_local.sh`. A nova suíte `tests/test_seguranca.py` tem 11 métodos de teste, além dos casos parametrizados internos, e foi executada isoladamente antes da suíte completa. Uma execução em andamento foi interrompida para reforçar a vinculação do teste ao instalador; o resultado acima é da reexecução completa final.

Os novos testes verificam: senha por stdin nos três destinos em PROD/DEV; precedência de `DB_PASS` e dos fallbacks por ambiente; ausência da senha em argv, logs e ambiente dos subprocessos LXC; recusa de entrada vazia, multilinear, CR e argumentos legados; xtrace sem senha; interrupção do deploy na falha do WordPress; limpeza de temporários em falha e TERM tratável; arquivo real com uid 0, grupo www-data e modo 0640; leitura e recusa de escrita direta por www-data; e manutenção de proprietário/grupo/modo após o atualizador PHP real da Fase 5, incluindo idempotência.

As operações de proprietário/grupo foram realizadas com `sudo -n` **somente em fixtures temporárias do sandbox**. Isso não equivale a verificar o arquivo da VM. Os comandos LXD/curl permanecem simulados; o mock guarda somente comprimento/hash e indicadores de presença de credenciais, nunca a senha recebida. PHP e OpenSSL são reais. Não houve inicialização de daemon LXD, MariaDB ou Apache real.

Permanecem pendentes: deploy real PROD/DEV, HTTPS 8444/8445 e navegador/CA/SAN, persistência após recriação, limites CPU/memória, monitoramento, coletor e permissões do arquivo realmente instalado na VM. A propriedade do diretório pai continua com o comportamento existente: a correção de `0640` impede escrita direta, não garante proteção contra remoção/substituição pelo servidor. Administradores ainda conseguem ler memória/ambiente e arquivos privados; não há promessa de sigilo contra root.

## Histórico da validação inicial

A revisão inicial foi realizada em **21/11/2026**, partindo da `dev` no commit `8145908f50e5dc1d33b69899820d31b06f129e98`. A base remota foi reconfirmada antes daquele empacotamento. Nenhum commit, push, merge ou comando destrutivo real foi executado naquela tarefa. Os resultados abaixo pertencem à validação inicial, anterior à correção de segurança.

## Resultado da execução

O comando abaixo terminou com **código de saída 0**:

```bash
bash tests/run_local.sh
```

Resultado final da suíte Python:

```text
Ran 34 tests in 174.931s

OK
Validações locais concluídas. Testes reais no LXD/navegador continuam pendentes.
```

Também passaram a verificação de sintaxe dos arquivos Bash, o lint PHP de `conf/atualiza-url-wp.php`, ShellCheck dos scripts da automação e dos instaladores, e o teste existente `tests/test_fase5_local.sh`. Esse último usa um arquivo WordPress de teste e confirma atualização idempotente das URLs; não altera o WordPress da equipe.

A primeira execução encontrou três falhas nos testes de integração TLS: eles procuravam o nome `atualiza-url-wp.php` como argumento completo, mas o script da Fase 5 envia `/root/atualiza-url-wp.php`. As verificações foram corrigidas para o caminho realmente utilizado. A suíte completa foi reexecutada e aprovada; não foi necessário modificar o atualizador PHP ou os scripts atuais da Fase 5 para corrigir essas três falhas.

## O que foi coberto localmente

Os testes verificaram planos sem chamadas LXD, isolamento lógico PROD/DEV, proteção do remoto local e recusa de projetos/profiles incompatíveis. Também cobriram recriação preservando nomes de volumes, recusa de exclusão sem confirmação, token específico por projeto/ambiente, proteção contra volumes alheios e interrupção de remoção de volumes quando a exclusão de instâncias falha.

Na integração TLS, foram verificadas geração e assinatura pela CA própria, cadeia do certificado, SAN, correspondência de chaves, reutilização dos materiais locais, portas 8444/8445 e argumentos de atualização das URLs WordPress. A criptografia utiliza **OpenSSL real**; os comandos LXD e curl desses testes são **simulados**.

Os testes de monitoramento e limites usam respostas simuladas, incluindo o destino exclusivo `dev-app` para a carga e tratamento de métricas indisponíveis. Há testes PHP com arquivos temporários para geração da configuração, preservação de uploads/temas existentes na cópia do core e atualização idempotente de URLs.

O coletor recusa `MOCK_STATE` para evitar gerar evidências falsas. Um teste separado verifica a remoção de campos potencialmente sensíveis dos JSONs, como `config`, `expanded_config` e cloud-init. Essa filtragem não elimina a necessidade de revisar todas as saídas reais antes de publicar.

Os scripts/templates atuais da Fase 5 e o seu teste local foram preservados, assim como as 11 evidências preexistentes. A branch antiga do Samuel não foi importada por inteiro: suas exclusões de evidências e `.DS_Store` não fazem parte desta revisão.

## O que permanece pendente

**Não houve acesso à VM da equipe nem utilização de um daemon LXD real.** Portanto, esta aprovação local não comprova criação de bridges/containers, execução de cloud-init, instalação e inicialização dos serviços, alcance de rede, funcionamento real do WordPress ou aplicação dos limites pelos cgroups.

Ainda é necessário executar e registrar na VM: implantação DEV e PROD com janela/backup quando necessário; remoção e reconstrução mantendo volumes; observação da persistência de posts e uploads; monitoramento e limites reais; validação de HTTPS WordPress em 8444/8445, incluindo navegador, CA, SAN e encaminhamento do VirtualBox. O procedimento está em [testes-na-vm.md](testes-na-vm.md).

A API/UI do LXD em **8443** não serve como prova do HTTPS WordPress. Testes simulados, `--dry-run` e curl com `-k` também não substituem essas evidências. Mantenha como pendente qualquer etapa não executada e não coloque este resultado local em `docs/evidencias` como se fosse teste real.
