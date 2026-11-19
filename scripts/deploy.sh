#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ajuda() {
  cat <<'TXT'
Uso: ENV=prod DB_PASS='...' ./scripts/deploy.sh [--dry-run] [--recreate] [--yes]
     ENV=dev  DB_PASS='...' ./scripts/deploy.sh
Opções: --env prod|dev; --recreate remove SOMENTE as três instâncias antes de criar;
        --yes dispensa a confirmação de --recreate; --dry-run só descreve o plano.
Variáveis: PROJETO=final-equipeN, POOL=pool-final, VM_HOST=127.0.0.1,
           DB_NAME=wordpress, DB_USER=wpuser, IMAGEM=ubuntu:24.04,
           DB_PASS_PROD/DB_PASS_DEV (alternativas a DB_PASS), BOOT_TIMEOUT=900.
Volumes são sempre preservados. Faça backup antes de recriar o ambiente existente.
TXT
}
RECRIAR=false; SIM=false; DRY_RUN=false
while (($#)); do
  case "$1" in
    --env) [[ $# -ge 2 ]] || falhar 'Falta o valor de --env.'; ENV="$2"; shift 2 ;;
    --recreate) RECRIAR=true; shift ;;
    --yes) SIM=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) ajuda; exit 0 ;;
    *) falhar "Parâmetro desconhecido: $1" ;;
  esac
done
carregar_config
VM_HOST="${VM_HOST:-127.0.0.1}"
DB_NAME="${DB_NAME:-wordpress}"; DB_USER="${DB_USER:-wpuser}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-900}"
[[ "$VM_HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || falhar 'VM_HOST deve ser um IPv4 ou nome DNS, sem protocolo, porta ou caminho.'
[[ "$BOOT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || falhar 'BOOT_TIMEOUT deve ser um inteiro positivo.'
[[ "$DB_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ && "$DB_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || falhar 'DB_NAME/DB_USER devem ser identificadores simples.'
URL="http://${VM_HOST}:${PORTA_HTTP}"
if "$DRY_RUN"; then
  printf 'PLANO (não consulta nem altera o LXD):\nProjeto: %s; ambiente: %s\nRede: %s (%s.0/24); pool: %s\n' "$PROJETO" "$ENV" "$REDE" "$SUBNET" "$POOL"
  printf 'Instâncias: %s\n' "${INSTANCIAS[*]}"
  printf 'Volumes mantidos/criados se ausentes: %s\n' "${VOLUMES[*]}"
  printf 'Importar profiles/; configurar MariaDB, WordPress e Nginx HTTP/HTTPS.\nURL: %s; HTTPS: https://%s:%s\n' "$URL" "$VM_HOST" "$PORTA_HTTPS"
  "$RECRIAR" && printf 'ATENÇÃO: --recreate apagará as instâncias e seus discos raiz, não os volumes customizados.\n'
  exit 0
fi
if [[ "$ENV" == prod ]]; then DB_PASS="${DB_PASS:-${DB_PASS_PROD:-}}"; else DB_PASS="${DB_PASS:-${DB_PASS_DEV:-}}"; fi
[[ -n "$DB_PASS" ]] || falhar 'Informe DB_PASS ou DB_PASS_PROD/DB_PASS_DEV. Não há senha padrão no código.'
[[ "$DB_PASS" =~ ^[a-zA-Z0-9_@%+=.:,-]+$ ]] || falhar 'Senha: use apenas letras, números e _ @ % + = . : , - (compatibilidade com a configuração SQL).'
exigir_comandos lxc python3 timeout
python3 -c 'import yaml' || falhar 'Instale python3-yaml (sudo apt install python3-yaml).'
checar_lxd
TMP="$(mktemp -d)"; chmod 700 "$TMP"
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
lx exec "${PREFIXO}db" -- bash /root/config-mariadb.sh "$SUBNET.11" "$DB_NAME" "$DB_USER" "$DB_PASS"
criar_instancia app 11
lx config device add "${PREFIXO}app" uploads disk pool="$POOL" source="${PREFIXO}vol-uploads" path=/var/www/html/wp-content/uploads
iniciar app
lx file push "$RAIZ/conf/instala-wp.sh" "${PREFIXO}app/root/instala-wp.sh"
lx exec "${PREFIXO}app" -- bash /root/instala-wp.sh "$SUBNET.12" "$DB_PASS" "$URL" "$DB_NAME" "$DB_USER"
criar_instancia proxy 10
iniciar proxy
python3 - "$RAIZ/conf/nginx-servico.conf" "$TMP/nginx-servico.conf" "$SUBNET.11" <<'PY'
import sys
with open(sys.argv[1]) as f: text=f.read()
if '__APP_IP__' not in text: raise SystemExit('Template nginx sem __APP_IP__.')
with open(sys.argv[2],'w') as f: f.write(text.replace('__APP_IP__',sys.argv[3]))
PY
# A chave TLS nasce no container e não é enviada ao GitHub.
lx exec "${PREFIXO}proxy" -- bash -s -- "$VM_HOST" <<'BASH'
set -euo pipefail
host="$1"
install -d -m 700 /etc/nginx/ssl
if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then san="IP:$host"; else san="DNS:$host"; fi
openssl req -x509 -nodes -newkey rsa:2048 -days 365 -keyout /etc/nginx/ssl/servico.key -out /etc/nginx/ssl/servico.crt -subj "/CN=$host" -addext "subjectAltName=$san" >/dev/null 2>&1
chmod 600 /etc/nginx/ssl/servico.key
BASH
lx file push "$TMP/nginx-servico.conf" "${PREFIXO}proxy/etc/nginx/sites-available/servico"
lx exec "${PREFIXO}proxy" -- bash -c 'ln -sf /etc/nginx/sites-available/servico /etc/nginx/sites-enabled/servico; rm -f /etc/nginx/sites-enabled/default; nginx -t; systemctl reload nginx'
lx config device add "${PREFIXO}proxy" porta-http proxy listen="tcp:0.0.0.0:$PORTA_HTTP" connect=tcp:127.0.0.1:80
lx config device add "${PREFIXO}proxy" porta-https proxy listen="tcp:0.0.0.0:$PORTA_HTTPS" connect=tcp:127.0.0.1:443
lx exec "${PREFIXO}db" -- systemctl is-active --quiet mariadb
lx exec "${PREFIXO}app" -- systemctl is-active --quiet apache2
lx exec "${PREFIXO}proxy" -- systemctl is-active --quiet nginx
# Checa também acesso ao banco com as credenciais da aplicação, sem imprimir a senha.
# shellcheck disable=SC2016
lx exec "${PREFIXO}app" -- env DB_HOST="$SUBNET.12" DB_USER="$DB_USER" DB_PASS="$DB_PASS" DB_NAME="$DB_NAME" php -r '$db=new mysqli(getenv("DB_HOST"),getenv("DB_USER"),getenv("DB_PASS"),getenv("DB_NAME")); if ($db->connect_errno) { exit(1); }' >/dev/null
lx exec "${PREFIXO}app" -- curl --fail --silent --show-error -o /dev/null http://127.0.0.1/
log "Serviços ativos em $ENV: $URL"
printf 'HTTPS (certificado autoassinado): https://%s:%s\nConclua o assistente do WordPress no navegador se o banco for novo.\n' "$VM_HOST" "$PORTA_HTTPS"
lx list -c ns4mDu
