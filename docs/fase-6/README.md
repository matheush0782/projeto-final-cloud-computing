# Fase 6 - Validação

## Objetivo
Validar a implementação da Fase 6 do projeto final de Cloud Computing, incluindo a auditoria de scripts, testes automatizados e configuração do ambiente.

## Estrutura da Fase 6

A Fase 6 foca em automação e validação do ambiente LXD, com scripts para:
- Snapshots de instâncias e volumes
- Backup e restauração de dados
- Limpeza de snapshots antigos
- Deploy e destroy do ambiente

### Scripts Principais

| Script | Descrição |
|--------|-----------|
| `scripts/01-snapshot.sh` | Cria snapshots de instâncias e volumes |
| `scripts/02-backup.sh` | Realiza backup de instâncias e volumes com checksums |
| `scripts/03-restore.sh` | Restaura instâncias e volumes a partir de snapshots ou imports |
| `scripts/04-limpeza.sh` | Remove snapshots antigos mantendo o número configurado |

### Dependências
- LXD 5.21.7 ou superior
- Ubuntu 24.04
- Pool de armazenamento `pool-final`
- Projeto LXD `final-equipeN`

### Profiles LXD
- `perfil-base`: Configura recursos, rede e disco raiz
- `perfil-proxy`: Instala Nginx e OpenSSL
- `perfil-app`: Instala Apache, PHP e extensões WordPress
- `perfil-db`: Instala MariaDB e define limite de memória de 1 GiB

### Redes
- `net-prod`: 10.10.10.0/24 — utilizada pelos containers da aplicação
- `net-dev`: 10.10.20.0/24 — ambiente de desenvolvimento

### Portas
- HTTP: 8081 (PROD) / 8082 (DEV)
- HTTPS WordPress: 8444 (PROD) / 8445 (DEV)
- API/LXD: 8443 (não é evidência de HTTPS WordPress)

## Workflow de Validação

O workflow GitHub Actions na branch `fase-6` executa as seguintes validações:
- Estrutura de arquivos e diretórios
- Sintaxe Bash dos scripts
- Testes automatizados com mocks

Para mais detalhes, consulte a documentação completa em `docs/automacao.md`.

## Segurança

### Scripts revisados
- `scripts/02-backup.sh`: Removidos exemplos destrutivos do final
- `scripts/03-restore.sh`: Removidos exemplos destrutivos do final  
- `scripts/04-limpeza.sh`: Removidos exemplos destrutivos do final

### Mock LXD
O arquivo `tests/mock_lxc.py` implementa os comandos essenciais:
- `lxc remote get-default` - retorna o remote padrão
- `lxc info local` - retorna informações do host local
- `lxc list`, `lxc config`, `lxc snapshot` - para testes de fluxo

## Testes

Execute os testes localmente:
```bash
# Verificar estrutura e sintaxe
bash tests/test_fase6.sh

# Executar testes Python com mock
python3 -m pytest tests/test_scripts.py -v
```

## Arrays CONSUMERS e INSTANCES

- **INSTANCES**: 6 containers (proxy, app, db, dev-proxy, dev-app, dev-db)
- **CONSUMERS**: 4 containers (app, db, dev-app, dev-db)

O dev-proxy e dev-db não estão em CONSUMERS porque:
- dev-proxy: container de proxy leve sem dados persistentes
- dev-db: o backup do banco de desenvolvimento é feito via volume dev-vol-db

O banco de dados de desenvolvimento (dev-db) possui um volume separado (`dev-vol-db`) que é incluído nos backups.

## Status da Correção

| Correção | Status | Evidência |
|----------|--------|-----------|
| Exemplos em 02-backup.sh | ✅ Corrigido | 11 linhas removidas |
| Exemplos em 03-restore.sh | ✅ Corrigido | 15 linhas removidas |
| Exemplos em 04-limpeza.sh | ✅ Corrigido | 18 linhas removidas |
| Mock lxc info | ✅ Implementado | Linhas 146-155 |
| Mock remote get-default | ✅ Implementado | Linhas 143-144 |
| Workflow GitHub | ✅ Criado | .github/workflows/fase-6.yml |
| Testes Fase 6 | ✅ Criado | tests/test_fase6.sh |
| Documentação | ✅ Criada | docs/fase-6/README.md |