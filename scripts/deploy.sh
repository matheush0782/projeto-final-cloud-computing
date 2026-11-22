#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2153
# Desative rastreamento antes de selecionar ou transmitir qualquer credencial.
set +x
set +v
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ajuda() {
  cat <<'TXT'
Uso: ENV=prod ./scripts/deploy.sh [--dry-run] [--recreate] [--yes]
     ENV=dev  ./scripts/deploy.sh [--http-only]
Opções: --env prod|dev; --recreate remove SOMENTE as três instâncias antes de criar;
        --yes dispensa a confirmação de --recreate; --dry-run só descreve o plano;
        --http-only não executa a Fase 5, não cria certificado nem publica HTTPS.
Variáveis: PROJETO=final-equipeN, POOL=pool-final, VM_HOST=127.0.0.1,
           DB_NAME=wordpress, DB_USER=wpuser, DB_PASS_PROD/DB_PASS_DEV,
           BOOT_TIMEOUT=900, WITH_TLS=1 (padrão; --http-only força 0).
Com TLS, informe IP_VM com o IPv4 real da VM. IP_SITE usa VM_HOST por padrão e
precisa ser IPv4. A CA e servico.* são gerados/reutilizados somente por fase5-tls.sh.
A instalação começa em HTTP; ao final da Fase 5, HTTPS vira o acesso canônico.
Volumes são sempre preservados. Faça backup antes de recriar o ambiente existente.
Leia a senha com read -rsp e exporte DB_PASS_PROD/DB_PASS_DEV antes do deploy.
Os scripts internos e a checagem PHP recebem a senha por stdin não interativo,
sem incluí-la em argv e sem criar um arquivo de senha nomeado no host.
TXT
}

RECRIAR=false
SIM=false
DRY_RUN=false
WITH_TLS="${WITH_TLS:-1}"
while (($#)); do
  case "$1" in
    --env) [[ $# -ge 2 ]] || falhar 'Falta o valor de --env.'; ENV="$2"; shift 2 ;;
    --recreate) RECRIAR=true; shift ;;
    --yes) SIM=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --http-only) WITH_TLS=0; shift ;;
    -h|--help) ajuda; exit 0 ;;
    *) falhar "Parâmetro desconhecido: $1" ;;
  esac
done
case "$WITH_TLS" in
  0) TLS_ATIVO=false ;;
  1) TLS_ATIVO=true ;;
  *) falhar 'WITH_TLS deve ser 0 ou 1; use --http-only para um deploy somente HTTP.' ;;
esac

carregar_config
VM_HOST="${VM_HOST:-127.0.0.1}"
DB_NAME="${DB_NAME:-wordpress}"
DB_USER="${DB_USER:-wpuser}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-900}"
[[ "$BOOT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || falhar 'BOOT_TIMEOUT deve ser um inteiro positivo.'
[[ "$DB_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ && "$DB_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || falhar 'DB_NAME/DB_USER devem ser identificadores simples.'

validar_ipv4() {
  local ip="$1" octeto
  local -a octetos
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a octetos <<< "$ip"
  (( ${#octetos[@]} == 4 )) || return 1
  for octeto in "${octetos[@]}"; do
    [[ "$octeto" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
    (( 10#$octeto <= 255 )) || return 1
  done
}

if "$TLS_ATIVO"; then
  # O dry-run permanece offline: não exige descobrir silenciosamente o IP real.
  if ! "$DRY_RUN"; then
    validar_ipv4 "$VM_HOST" || falhar 'Com TLS, VM_HOST deve ser um IPv4 sem protocolo, porta ou caminho.'
    [[ -n "${IP_VM:-}" ]] || falhar 'Com TLS, informe IP_VM com o IPv4 real da VM (consulte "ip -br addr"); o deploy não detecta esse endereço silenciosamente.'
    validar_ipv4 "$IP_VM" || falhar 'IP_VM deve ser IPv4 válido (consulte "ip -br addr").'
    IP_SITE="${IP_SITE:-$VM_HOST}"
    validar_ipv4 "$IP_SITE" || falhar 'IP_SITE deve ser IPv4 válido; ele é o endereço usado pelo navegador.'
  fi
else
  [[ "$VM_HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || falhar 'VM_HOST deve ser um IPv4 ou nome DNS, sem protocolo, porta ou caminho.'
fi

URL="http://${VM_HOST}:${PORTA_HTTP}"
TLS_DIR="$RAIZ/conf/tls/$ENV"

preflight_certificados() {
  "$TLS_ATIVO" || return 0
  [[ -f "$RAIZ/scripts/fase5-tls.sh" ]] || falhar 'scripts/fase5-tls.sh ausente; não há implementação TLS alternativa no deploy.'
  [[ -f "$RAIZ/conf/nginx-servico-https.conf" ]] || falhar 'Template HTTPS ausente; a Fase 5 não pode concluir o TLS.'
  [[ -f "$RAIZ/conf/atualiza-url-wp.php" ]] || falhar 'Script de atualização de URL ausente; a Fase 5 não pode concluir o TLS.'
  [[ -e "$TLS_DIR" && ! -d "$TLS_DIR" ]] && falhar "Diretório TLS inválido (não é diretório): $TLS_DIR"

  local presentes=0 arquivo
  local -a arquivos=(ca.key ca.crt servico.key servico.crt)
  for arquivo in "${arquivos[@]}"; do
    [[ -e "$TLS_DIR/$arquivo" ]] && presentes=$((presentes + 1))
  done
  if (( presentes == 0 )); then
    # A Fase 5 criará a CA em diretório ainda vazio/ausente, de forma atômica.
    return 0
  fi
  (( presentes == ${#arquivos[@]} )) || falhar "Certificados TLS incompletos em $TLS_DIR; preservados para verificação manual antes de qualquer --recreate."
  for arquivo in "${arquivos[@]}"; do
    [[ -f "$TLS_DIR/$arquivo" ]] || falhar "Arquivo TLS inválido ou não regular: $TLS_DIR/$arquivo"
  done

  if ! openssl verify -CAfile "$TLS_DIR/ca.crt" "$TLS_DIR/servico.crt" >/dev/null 2>&1; then
    falhar "Certificado do serviço não é verificável pela CA em $TLS_DIR; nenhuma instância foi alterada."
  fi
  if ! cmp -s \
      <(openssl pkey -in "$TLS_DIR/ca.key" -pubout 2>/dev/null) \
      <(openssl x509 -in "$TLS_DIR/ca.crt" -pubkey -noout 2>/dev/null); then
    falhar "Chave e certificado da CA não correspondem em $TLS_DIR; nenhuma instância foi alterada."
  fi
  if ! cmp -s \
      <(openssl pkey -in "$TLS_DIR/servico.key" -pubout 2>/dev/null) \
      <(openssl x509 -in "$TLS_DIR/servico.crt" -pubkey -noout 2>/dev/null); then
    falhar "Chave e certificado do serviço não correspondem em $TLS_DIR; nenhuma instância foi alterada."
  fi

  local san
  if ! san="$(openssl x509 -in "$TLS_DIR/servico.crt" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed 's/^[[:space:]]*//')"; then
    falhar "Não foi possível ler subjectAltName do certificado em $TLS_DIR; nenhuma instância foi alterada."
  fi
  for arquivo in "$IP_VM" "$IP_SITE" 127.0.0.1; do
    grep -Fqx "IP Address:$arquivo" <<< "$san" || falhar "Certificado existente não cobre IP:$arquivo em $TLS_DIR; ajuste a CA/certificado sem sobrescrever chaves."
  done
}

if "$DRY_RUN"; then
  printf 'PLANO (não consulta nem altera o LXD):\nProjeto: %s; ambiente: %s\nRede: %s (%s.0/24); pool: %s\n' "$PROJETO" "$ENV" "$REDE" "$SUBNET" "$POOL"
  printf 'Instâncias: %s\n' "${INSTANCIAS[*]}"
  printf 'Volumes mantidos/criados se ausentes: %s\n' "${VOLUMES[*]}"
  printf 'Instalação inicial: HTTP em %s; apenas Nginx HTTP80 será renderizado pelo deploy.\n' "$URL"
  if "$TLS_ATIVO"; then
    printf 'TLS: habilitado por padrão; após os guests subirem, chamar fase5-tls.sh para CA, servico.* em /etc/nginx/ssl, HTTPS e URL canônica.\n'
    printf 'TLS real exigirá IP_VM IPv4 informado; IP_SITE usará VM_HOST (%s) por padrão.\n' "$VM_HOST"
    printf 'Porta HTTPS externa prevista: %s; 8443 é a API/LXD, não a porta do WordPress.\n' "$PORTA_HTTPS"
  else
    printf 'TLS: desabilitado por --http-only; não gerar certificado e não publicar porta 443/HTTPS.\n'
    printf 'HTTP-only é independente: mantém somente a porta HTTP externa %s; 8443 continua sendo API/LXD, não WordPress.\n' "$PORTA_HTTP"
  fi
  "$RECRIAR" && printf 'ATENÇÃO: --recreate apagará as instâncias e seus discos raiz, não os volumes customizados.\n'
  exit 0
fi

if [[ "$ENV" == prod ]]; then
  SENHA_BANCO="${DB_PASS:-${DB_PASS_PROD:-}}"
else
  SENHA_BANCO="${DB_PASS:-${DB_PASS_DEV:-}}"
fi
declare +x SENHA_BANCO
unset DB_PASS DB_PASS_PROD DB_PASS_DEV
[[ -n "$SENHA_BANCO" ]] || falhar 'Informe DB_PASS ou DB_PASS_PROD/DB_PASS_DEV. Não há senha padrão no código.'
[[ "$SENHA_BANCO" =~ ^[a-zA-Z0-9_@%+=.:,-]+$ ]] || falhar 'Senha: use apenas letras, números e _ @ % + = . : , - (compatibilidade com a configuração SQL).'

exigir_comandos lxc python3 timeout
python3 -c 'import yaml' || falhar 'Instale python3-yaml (sudo apt install python3-yaml).'
if "$TLS_ATIVO"; then
  # OpenSSL/curl são necessários somente no caminho TLS; não oneram HTTP-only.
  exigir_comandos openssl curl
  preflight_certificados
fi
checar_lxd
TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf -- "$TMP"' EXIT
trap 'printf "Falha no deploy. Instâncias parciais e volumes foram mantidos para diagnóstico.\n" >&2' ERR

# Renderiza o profile base sem editar o arquivo versionado. DEV sobrescreve eth0 por instância.
for papel in base proxy app db; do
  [[ -f "$RAIZ/profiles/perfil-$papel.yaml" ]] || falhar "Profile ausente: perfil-$papel.yaml"
  python3 - "$RAIZ/profiles/perfil-$papel.yaml" "$TMP/perfil-$papel.yaml" "$POOL" "$papel" <<'PY'
import sys,yaml
src,dst,pool,role=sys.argv[1:]
with open(src) as f: p=yaml.safe_load(f)
if not isinstance(p,dict) or not isinstance(p.get('config'),dict):
    raise SystemExit('Profile inválido: '+src)
if role=='base':
    p['devices']['root']['pool']=pool
    p['devices']['eth0']['network']='net-prod'
with open(dst,'w') as f: yaml.safe_dump(p,f,sort_keys=False)
PY
done
for arquivo in config-mariadb.sh instala-wp.sh nginx-servico.conf; do
  [[ -f "$RAIZ/conf/$arquivo" ]] || falhar "Configuração ausente: conf/$arquivo"
done
# Não confundir erros da API com recursos ausentes.
PROJETOS="$(lx_global project list --format=json)"
if python3 -c 'import json,sys; sys.exit(0 if any(p["name"]==sys.argv[1] for p in json.loads(sys.argv[2])) else 1)' "$PROJETO" "$PROJETOS"; then
  validar_projeto
  EXISTENTES="$(listar_instancias)"
  TEM_INSTANCIA=false
  for nome in "${INSTANCIAS[@]}"; do
    if grep -Fxq -- "$nome" <<< "$EXISTENTES"; then TEM_INSTANCIA=true; fi
  done
  if "$TEM_INSTANCIA"; then
    "$RECRIAR" || falhar 'Há instâncias deste ambiente. Use destroy.sh após backup, ou --recreate com confirmação. Nenhuma instância foi excluída.'
    if ! "$SIM"; then confirmar "Recriar $ENV em $PROJETO perde os discos raiz, mas mantém banco/uploads." "$PROJETO/$ENV"; fi
  fi
else
  TEM_INSTANCIA=false
fi

# Verifica perfis compartilhados antes de qualquer exclusão/criação.
PERFIS="$(lx_global profile list --format=json)"
for papel in base proxy app db; do
  nome="perfil-$papel"
  python3 - "$TMP/$nome.yaml" "$nome" "$PERFIS" <<'PY'
import sys,json,yaml
with open(sys.argv[1]) as f: want=yaml.safe_load(f)
old=next((p for p in json.loads(sys.argv[3]) if p['name']==sys.argv[2]),None)
if old:
    same=all((old.get(k) or {})==(want.get(k) or {}) for k in ('config','devices'))
    if not same and old.get('used_by'):
        raise SystemExit('Profile compartilhado '+sys.argv[2]+' difere do arquivo e está em uso. Revise-o com a equipe; não foi alterado.')
PY
done
# Redes/pool são globais; volumes e instâncias pertencem ao projeto selecionado.
REDES="$(lx_global network list --format=json)"
for rede in net-prod "$REDE"; do
  [[ "$rede" == net-prod ]] && endereco='10.10.10.1/24' || endereco="$SUBNET.1/24"
  python3 -c 'import json,sys
n=next((n for n in json.loads(sys.argv[1]) if n["name"]==sys.argv[2]),None)
if n and (not n.get("managed") or n.get("type")!="bridge" or n.get("config",{}).get("ipv4.address")!=sys.argv[3] or n.get("config",{}).get("ipv4.nat")!="true" or n.get("config",{}).get("ipv6.address")!="none"):
 raise SystemExit("Rede existente incompatível: "+sys.argv[2])
' "$REDES" "$rede" "$endereco"
done
POOLS="$(lx_global storage list --format=json)"
python3 -c 'import json,sys
p=next((p for p in json.loads(sys.argv[1]) if p["name"]==sys.argv[2]),None)
if p and p.get("driver")!="dir": raise SystemExit("Este roteiro exige pool com driver dir.")
' "$POOLS" "$POOL"

if "$TEM_INSTANCIA"; then
  ENV="$ENV" PROJETO="$PROJETO" POOL="$POOL" bash "$RAIZ/scripts/destroy.sh" --yes
fi
if ! python3 -c 'import json,sys; sys.exit(0 if any(p["name"]==sys.argv[1] for p in json.loads(sys.argv[2])) else 1)' "$PROJETO" "$PROJETOS"; then
  lx_global project create "$PROJETO" -c features.images=false -c features.profiles=false -c features.networks=false -c features.storage.volumes=true
fi
validar_projeto
rede() {
  local nome="$1" endereco="$2"
  if ! python3 -c 'import json,sys; sys.exit(0 if any(n["name"]==sys.argv[1] for n in json.loads(sys.argv[2])) else 1)' "$nome" "$REDES"; then
    lx_global network create "$nome" ipv4.address="$endereco" ipv4.nat=true ipv6.address=none
    REDES="$(lx_global network list --format=json)"
  fi
}
rede net-prod '10.10.10.1/24'
rede "$REDE" "$SUBNET.1/24"
if ! python3 -c 'import json,sys; sys.exit(0 if any(p["name"]==sys.argv[1] for p in json.loads(sys.argv[2])) else 1)' "$POOL" "$POOLS"; then lx_global storage create "$POOL" dir; fi
VOLUMES_JSON="$(lx storage volume list "$POOL" --format=json)"
for volume in "${VOLUMES[@]}"; do
  if ! python3 -c 'import json,sys; sys.exit(0 if any(v["name"]==sys.argv[1] and v["type"]=="custom" for v in json.loads(sys.argv[2])) else 1)' "$volume" "$VOLUMES_JSON"; then
    lx storage volume create "$POOL" "$volume"
  fi
done
for papel in base proxy app db; do
  nome="perfil-$papel"
  if ! python3 -c 'import json,sys; sys.exit(0 if any(p["name"]==sys.argv[1] for p in json.loads(sys.argv[2])) else 1)' "$nome" "$PERFIS"; then
    lx_global profile create "$nome"
  fi
  # Mesmo conteúdo não precisa ser reaplicado em instâncias de outro ambiente.
  if ! python3 - "$TMP/$nome.yaml" "$nome" "$PERFIS" <<'PY'
import sys,json,yaml
with open(sys.argv[1]) as f: want=yaml.safe_load(f)
old=next((p for p in json.loads(sys.argv[3]) if p['name']==sys.argv[2]),None)
sys.exit(0 if old and all((old.get(k) or {})==(want.get(k) or {}) for k in ('config','devices')) else 1)
PY
  then lx_global profile edit "$nome" < "$TMP/$nome.yaml"; fi
done
criar_instancia() {
  local papel="$1" sufixo_ip="$2"
  log "Criando ${PREFIXO}$papel"
  lx init "$IMAGEM" "${PREFIXO}$papel" -p perfil-base -p "perfil-$papel"
  lx config device override "${PREFIXO}$papel" eth0 network="$REDE" ipv4.address="$SUBNET.$sufixo_ip"
}
iniciar() {
  local nome="${PREFIXO}$1" prazo=$((SECONDS + BOOT_TIMEOUT))
  lx start "$nome"
  until lx exec "$nome" -- true >/dev/null 2>&1; do
    ((SECONDS < prazo)) || falhar "Timeout aguardando exec em $nome."
    sleep 2
  done
  command timeout "$BOOT_TIMEOUT" lxc --project="$PROJETO" exec "$nome" -- cloud-init status --wait
}

criar_instancia db 12
lx config device add "${PREFIXO}db" dados disk pool="$POOL" source="${PREFIXO}vol-db" path=/var/lib/mysql
iniciar db
lx file push "$RAIZ/conf/config-mariadb.sh" "${PREFIXO}db/root/config-mariadb.sh"
printf '%s\n' "$SENHA_BANCO" | lx exec "${PREFIXO}db" --mode=non-interactive -- bash /root/config-mariadb.sh --password-stdin "$SUBNET.12" "$SUBNET.11" "$DB_NAME" "$DB_USER"
criar_instancia app 11
lx config device add "${PREFIXO}app" uploads disk pool="$POOL" source="${PREFIXO}vol-uploads" path=/var/www/html/wp-content/uploads
iniciar app
lx file push "$RAIZ/conf/instala-wp.sh" "${PREFIXO}app/root/instala-wp.sh"
printf '%s\n' "$SENHA_BANCO" | lx exec "${PREFIXO}app" --mode=non-interactive -- bash /root/instala-wp.sh --password-stdin "$SUBNET.12" "$URL" "$DB_NAME" "$DB_USER"
criar_instancia proxy 10
iniciar proxy
python3 - "$RAIZ/conf/nginx-servico.conf" "$TMP/nginx-servico.conf" "$SUBNET.11" <<'PY'
import sys
with open(sys.argv[1]) as f: text=f.read()
if '__APP_IP__' not in text: raise SystemExit('Template nginx sem __APP_IP__.')
if text.count('server {') != 1 or text.count('listen ') != 1 or 'listen 80' not in text:
    raise SystemExit('Template nginx do deploy deve conter somente HTTP; HTTPS é responsabilidade da Fase 5.')
with open(sys.argv[2],'w') as f: f.write(text.replace('__APP_IP__',sys.argv[3]))
PY
lx file push "$TMP/nginx-servico.conf" "${PREFIXO}proxy/etc/nginx/sites-available/servico"
lx exec "${PREFIXO}proxy" -- bash -c 'ln -sf /etc/nginx/sites-available/servico /etc/nginx/sites-enabled/servico; rm -f /etc/nginx/sites-enabled/default; nginx -t; systemctl reload nginx'
# O deploy publica somente HTTP; certificados e o endpoint seguro pertencem à Fase 5.
lx config device add "${PREFIXO}proxy" porta-http proxy listen="tcp:0.0.0.0:$PORTA_HTTP" connect=tcp:127.0.0.1:80

lx exec "${PREFIXO}db" -- systemctl is-active --quiet mariadb
lx exec "${PREFIXO}app" -- systemctl is-active --quiet apache2
lx exec "${PREFIXO}proxy" -- systemctl is-active --quiet nginx
# Checa acesso ao banco: a senha também chega ao PHP por stdin, nunca por env/argv.
# shellcheck disable=SC2016
printf '%s\n' "$SENHA_BANCO" | lx exec "${PREFIXO}app" --mode=non-interactive -- php -r '$senha=rtrim(stream_get_contents(STDIN), "\r\n"); mysqli_report(MYSQLI_REPORT_OFF); $db=@new mysqli($argv[1],$argv[2],$senha,$argv[3]); if ($db->connect_errno) { exit(1); }' "$SUBNET.12" "$DB_USER" "$DB_NAME" >/dev/null 2>&1
unset SENHA_BANCO
lx exec "${PREFIXO}app" -- curl --fail --silent --show-error -o /dev/null http://127.0.0.1/

if "$TLS_ATIVO"; then
  # Única implementação de CA/certificados/HTTPS; também atualiza o WordPress para a URL canônica.
  ENV="$ENV" PROJETO="$PROJETO" POOL="$POOL" IP_VM="$IP_VM" IP_SITE="$IP_SITE" bash "$RAIZ/scripts/fase5-tls.sh"
  log "Serviços ativos em $ENV: instalação iniciou em $URL; HTTPS agora é canônico após fase5-tls.sh."
  printf 'HTTPS foi configurado pela Fase 5 em https://%s:%s; HTTP redireciona conforme o template HTTPS.\n' "$IP_SITE" "$PORTA_HTTPS"
else
  log "Serviços ativos em $ENV somente por HTTP: $URL"
  printf 'HTTP-only: porta externa %s publicada; nenhum certificado foi gerado e nenhuma porta 443 foi publicada.\n' "$PORTA_HTTP"
fi
printf 'A porta 8443 é da API/LXD e não do WordPress.\n'
lx list -c ns4mDu
