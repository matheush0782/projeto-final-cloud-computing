# Fase 5 — Acesso, permissões e HTTPS (integração com automação)

## Arquivos e integração

A Fase 5 usa `scripts/common.sh` da PR de automação: `PROJETO` (ex.: `final-equipeN`), `ENV=prod|dev`, redes e nomes de instâncias seguem o mesmo padrão do `deploy.sh`.

- PROD: `proxy` / `app`, HTTP 8081, HTTPS **8444**.
- DEV: `dev-proxy` / `dev-app`, HTTP 8082, HTTPS **8445**.
- Caminhos dentro dos proxies: `/etc/nginx/ssl/servico.crt` e `/etc/nginx/ssl/servico.key`.
- Materiais TLS **locais e privados** (fora do Git): `conf/tls/prod/` e `conf/tls/dev/`.
- O template `conf/nginx-servico-https.conf` substitui `__APP_IP__` e `__HTTPS_PORT__` para cada ambiente.

**Importante:** a automação original gera um certificado autoassinado e instala uma configuração HTTPS básica; a Fase 5 é aplicada **depois** para substituir esse certificado por um certificado assinado pela CA própria. Se o ambiente for destruído/recriado, execute novamente a Fase 5. Os materiais TLS locais da VM devem ser preservados em backup seguro.

## Antes de executar

1. Faça backup dos dados e confirme que o `deploy.sh` correspondente já criou e iniciou as instâncias.
2. Confirme o nome exato do projeto com `lxc project list` e o IP da VM com `ip -br addr`.
3. Garanta que o host VirtualBox encaminhe 8444→8444 (e, se necessário, 8445→8445). Para a API de gerenciamento, a porta 8443 é independente.
4. Não compartilhe senhas, tokens nem chaves privadas.

## Exemplos na VM (PROD)

```bash
# Assumindo que a integração das duas PRs está presente no clone da VM.
PROJETO=final-equipeN bash scripts/fase5-acesso.sh

# Exemplo ilustrativo: substitua IP_VM pelo IP real, mesmo que IP_SITE seja 127.0.0.1.
ENV=prod PROJETO=final-equipeN IP_VM=10.0.2.15 IP_SITE=127.0.0.1 bash scripts/fase5-tls.sh
```

## Exemplo DEV

```bash
ENV=dev PROJETO=final-equipeN IP_VM=10.0.2.15 IP_SITE=127.0.0.1 bash scripts/fase5-tls.sh
```

**Atenção:** `10.0.2.15` é apenas um exemplo, não um IP verificado da sua VM.

## Provas e evidências

- `lxc config trust list` e clientes admin/operador efetivamente registrados.
- Como operador: `lxc list operador: --project final-equipeN` funciona e `--project default` é negado.
- `lxc --project=final-equipeN config device list proxy` mostra `porta-https` **uma única vez**.
- `lxc --project=final-equipeN exec proxy -- nginx -t` passa.
- `openssl x509 -in conf/tls/prod/servico.crt -noout -ext subjectAltName` inclui os IPs.
- `curl --cacert conf/tls/prod/ca.crt -I https://127.0.0.1:8444` valida HTTPS sem `-k` na VM.
- Browser do hospedeiro: `https://127.0.0.1:8444` após importar apenas `ca.crt` como CA confiável (com procedência verificada).
- Se usar `servico.lab`, configurar resolução desse nome até o IP correto e garantir que ele apareça no SAN.
- Guardar prints de URL, cadeia de certificação, site WordPress e resposta HTTP (sem segredos).

**Não confunda:** `https://127.0.0.1:8443` é a API/UI do LXD, **não** o WordPress.

## Reexecução sem conflitos

- A Fase 5 não recria o dispositivo `porta-https`: verifica e atualiza somente quando necessário.
- A configuração Nginx é ativada por link simbólico idempotente em `sites-enabled`.
- Os certificados existentes são reutilizados e verificados; divergências de SAN interrompem o procedimento para revisão manual, **sem sobrescrever chaves**.
- A alteração de `WP_HOME` e `WP_SITEURL` é feita por PHP e conserva o restante do `wp-config.php`.

## Status

Arquivos preparados para integração. **Testes locais de sintaxe não equivalem a validação real no LXD**. Execução na VM, importação da CA e evidências reais ainda são necessárias.
