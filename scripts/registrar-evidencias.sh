#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ajuda() {
  cat <<'TXT'
Uso: ./scripts/registrar-evidencias.sh [opções]
Opções:
  --env prod|dev    Ambiente/projeto a consultar (padrão: ENV ou prod).
  --out DIR         Diretório novo para a coleta; não pode existir.
  --host IPv4       IP usado nas URLs HTTP/HTTPS (padrão: IP_SITE ou 127.0.0.1).
  -h, --help        Mostra esta ajuda sem consultar LXD.

A coleta é somente leitura no remoto local, não executa deploy, destroy, carga,
trust ou configuração de certificados. --host é entrada explícita: não há
descoberta automática do IP real da VM. O HTTPS usa conf/tls/ENV/ca.crt,
sem -k e sem salvar o payload da página.
TXT
}

ENV_VALUE="${ENV:-prod}"
OUT_ARG=''
HOST_ARG=''
while (($#)); do
  case "$1" in
    --env)
      (($# >= 2)) || { printf 'ERRO: --env exige prod ou dev.\n' >&2; exit 2; }
      ENV_VALUE="$2"
      shift 2
      ;;
    --out)
      (($# >= 2)) || { printf 'ERRO: --out exige um diretório novo.\n' >&2; exit 2; }
      OUT_ARG="$2"
      shift 2
      ;;
    --host)
      (($# >= 2)) || { printf 'ERRO: --host exige um IPv4.\n' >&2; exit 2; }
      HOST_ARG="$2"
      shift 2
      ;;
    -h|--help)
      ajuda
      exit 0
      ;;
    *)
      printf 'ERRO: opção desconhecida: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ -n "${MOCK_STATE+x}" ]]; then
  printf 'ERRO: MOCK_STATE definido; este coletor só aceita LXD local real.\n' >&2
  exit 2
fi

ENV="$ENV_VALUE"
IP_SITE="${HOST_ARG:-${IP_SITE:-127.0.0.1}}"
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
validar_ipv4 "$IP_SITE" || {
  printf 'ERRO: --host/IP_SITE deve ser IPv4 estrito (ex.: 127.0.0.1).\n' >&2
  exit 2
}

[[ -f "$SCRIPT_DIR/common.sh" ]] || {
  printf 'ERRO: scripts/common.sh não encontrado; use a integração que o fornece.\n' >&2
  exit 2
}
# common.sh fornece as funções e variáveis de configuração consumidas abaixo.
# shellcheck disable=SC1091,SC2153
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"
carregar_config

umask 077
if [[ -n "$OUT_ARG" ]]; then
  [[ ! -e "$OUT_ARG" && ! -L "$OUT_ARG" ]] || falhar "--out já existe; nenhum arquivo foi sobrescrito: $OUT_ARG"
  mkdir -p -- "$OUT_ARG" || falhar "Não foi possível criar --out: $OUT_ARG"
  OUT="$OUT_ARG"
else
  PAI="$RAIZ/docs/evidencias/fases7-8"
  mkdir -p -- "$PAI" || falhar "Não foi possível criar $PAI"
  carimbo="$(date -u '+%Y%m%dT%H%M%SZ')" || falhar 'Não foi possível obter a hora UTC.'
  numero=0
  while :; do
    sufixo=''
    (( numero > 0 )) && sufixo="-$numero"
    OUT="$PAI/${ENV}-${carimbo}${sufixo}"
    if mkdir -m 700 -- "$OUT" 2>/dev/null; then
      break
    fi
    [[ -e "$OUT" || -L "$OUT" ]] || falhar "Não foi possível criar diretório de evidências: $OUT"
    ((numero += 1))
  done
fi
chmod 700 -- "$OUT"
STATUS_LOG="$OUT/status.log"
: > "$STATUS_LOG"
chmod 600 -- "$STATUS_LOG"
printf 'ARQUIVO\tEXIT_CODE\tSTATUS\n' > "$STATUS_LOG"
FAILURES=0
PENDENTES=0
LAST_RC=0

registrar_status() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STATUS_LOG"
}
capturar_texto() {
  local nome="$1" arquivo rc status
  shift
  arquivo="$OUT/$nome"
  if "$@" > "$arquivo" 2>&1; then rc=0; else rc=$?; fi
  if (( rc == 0 )); then status=OK; else status=FALHOU; FAILURES=$((FAILURES + 1)); fi
  printf '\nEXIT_CODE=%s\nSTATUS=%s\n' "$rc" "$status" >> "$arquivo"
  chmod 600 -- "$arquivo"
  registrar_status "$nome" "$rc" "$status"
  LAST_RC="$rc"
}
capturar_bruto() {
  local nome="$1" arquivo rc status
  shift
  arquivo="$OUT/$nome"
  if "$@" > "$arquivo" 2>&1; then rc=0; else rc=$?; fi
  if (( rc == 0 )); then status=OK; else status=FALHOU; FAILURES=$((FAILURES + 1)); fi
  chmod 600 -- "$arquivo"
  registrar_status "$nome" "$rc" "$status"
  LAST_RC="$rc"
}
capturar_funcao() {
  local nome="$1" arquivo rc status
  shift
  arquivo="$OUT/$nome"
  if ( "$@" ) > "$arquivo" 2>&1; then rc=0; else rc=$?; fi
  if (( rc == 0 )); then status=OK; else status=FALHOU; FAILURES=$((FAILURES + 1)); fi
  printf '\nEXIT_CODE=%s\nSTATUS=%s\n' "$rc" "$status" >> "$arquivo"
  chmod 600 -- "$arquivo"
  registrar_status "$nome" "$rc" "$status"
  LAST_RC="$rc"
}
pular_pendente() {
  local nome="$1" detalhe="$2" arquivo="$OUT/$1"
  : > "$arquivo"
  printf 'EXIT_CODE=125\nSTATUS=PENDENTE\nMOTIVO=%s\n' "$detalhe" >> "$arquivo"
  chmod 600 -- "$arquivo"
  registrar_status "$nome" 125 PENDENTE
  FAILURES=$((FAILURES + 1))
  PENDENTES=$((PENDENTES + 1))
}

# lxc list JSON também pode conter config/expanded_config com cloud-init.
# Salva somente os campos públicos necessários; nunca configurações completas.
filtrar_json_publico() {
  python3 -c '
import json,sys
kind=sys.argv[1]
items=json.load(sys.stdin)
keys={
    "instances": ("name","status","type","architecture"),
    "networks": ("name","type","status","managed"),
    "volumes": ("name","type","content_type","status","used_by"),
}[kind]
output=[]
for item in items:
    safe={key:item[key] for key in keys if key in item}
    if kind=="networks":
        cfg=item.get("config",{})
        safe["config"]={key:cfg[key] for key in ("ipv4.address","ipv4.nat","ipv6.address") if key in cfg}
    output.append(safe)
json.dump(output,sys.stdout,ensure_ascii=False,indent=2)
print()
' "$1"
}
listar_publico() { lx list --format=json | filtrar_json_publico instances; }
redes_publicas() { lx_global network list --format=json | filtrar_json_publico networks; }
volumes_publicos() { lx storage volume list "$POOL" --format=json | filtrar_json_publico volumes; }

capturar_texto date-utc.txt date -u '+%Y-%m-%dT%H:%M:%SZ'
capturar_texto date-local.txt date '+%Y-%m-%dT%H:%M:%S%z'
capturar_texto git-hash.txt git -C "$RAIZ" rev-parse HEAD
capturar_texto lxc-version.txt lxc --version
capturar_texto host-nproc.txt nproc
capturar_texto host-free.txt free -h
capturar_texto host-df.txt df -hP /

capturar_funcao lxd-check.txt checar_lxd
LXD_READY=false
(( LAST_RC == 0 )) && LXD_READY=true

LIST_OK=false
if "$LXD_READY"; then
  capturar_bruto lxc-list.json listar_publico
  (( LAST_RC == 0 )) && LIST_OK=true
  capturar_bruto networks.json redes_publicas
  capturar_bruto volumes.json volumes_publicos
else
  pular_pendente lxc-list.json 'LXD local indisponível ou remoto diferente de local.'
  pular_pendente networks.json 'LXD local indisponível ou remoto diferente de local.'
  pular_pendente volumes.json 'LXD local indisponível ou remoto diferente de local.'
fi

# Usa somente a listagem explícita do projeto para decidir quais guests são esperados.
declare -A ESTADOS=()
if "$LIST_OK"; then
  if ESTADOS_TEXTO="$(python3 - "$OUT/lxc-list.json" "${INSTANCIAS[@]}" <<'PY'
import json
import sys
arquivo, nomes = sys.argv[1], sys.argv[2:]
with open(arquivo, encoding='utf-8') as stream:
    itens = json.load(stream)
por_nome = {item.get('name'): item for item in itens if isinstance(item, dict)}
for nome in nomes:
    item = por_nome.get(nome)
    if item is None:
        print(f'{nome}\tMISSING')
        continue
    estado = item.get('status')
    if not estado and isinstance(item.get('state'), dict):
        estado = item['state'].get('status')
    print(f'{nome}\t{str(estado or "UNKNOWN").upper()}')
PY
  )"; then
    while IFS=$'\t' read -r nome estado; do
      [[ -n "$nome" ]] && ESTADOS["$nome"]="$estado"
    done <<< "$ESTADOS_TEXTO"
  fi
fi

GUEST_PROBE='printf "NPROC="; nproc; printf "FREE="; free -h; printf "DF="; df -hP /'
for nome in "${INSTANCIAS[@]}"; do
  estado="${ESTADOS[$nome]:-MISSING}"
  if [[ "$estado" == MISSING ]]; then
    pular_pendente "guest-${nome}.txt" 'Container esperado ausente no projeto.'
  elif [[ "$estado" != RUNNING ]]; then
    pular_pendente "guest-${nome}.txt" "Container esperado não está RUNNING (estado: $estado)."
  else
    capturar_texto "guest-${nome}.txt" lx exec "$nome" -- sh -c "$GUEST_PROBE"
  fi
done

if [[ -f "$SCRIPT_DIR/monitor.sh" ]]; then
  capturar_texto monitor-once.txt bash "$SCRIPT_DIR/monitor.sh" --env "$ENV" --once
else
  pular_pendente monitor-once.txt 'scripts/monitor.sh não encontrado nesta integração.'
fi
if [[ -f "$SCRIPT_DIR/test-limits.sh" ]]; then
  # Sem a opção de carga: esta evidência nunca gera carga de CPU ou memória.
  capturar_texto test-limits.txt bash "$SCRIPT_DIR/test-limits.sh" --env "$ENV"
else
  pular_pendente test-limits.txt 'scripts/test-limits.sh não encontrado nesta integração.'
fi

URL_HTTP="http://${IP_SITE}:${PORTA_HTTP}/"
URL_HTTPS="https://${IP_SITE}:${PORTA_HTTPS}/"
RESOLVE_ARGS=()
if [[ "$IP_SITE" != 127.0.0.1 ]]; then
  RESOLVE_ARGS=(--resolve "${IP_SITE}:${PORTA_HTTP}:127.0.0.1")
fi
capturar_texto http-response.txt curl --fail --silent --show-error --head --max-time 20 --connect-timeout 5 \
  --dump-header - --output /dev/null --write-out $'\nHTTP_CODE=%{http_code}\n' "${RESOLVE_ARGS[@]}" "$URL_HTTP"

CA="$RAIZ/conf/tls/$ENV/ca.crt"
if [[ -r "$CA" ]]; then
  RESOLVE_HTTPS=()
  if [[ "$IP_SITE" != 127.0.0.1 ]]; then
    RESOLVE_HTTPS=(--resolve "${IP_SITE}:${PORTA_HTTPS}:127.0.0.1")
  fi
  capturar_texto https-response.txt curl --fail --silent --show-error --head --max-time 20 --connect-timeout 5 \
    --cacert "$CA" --dump-header - --output /dev/null --write-out $'\nHTTP_CODE=%{http_code}\n' \
    "${RESOLVE_HTTPS[@]}" "$URL_HTTPS"
else
  pular_pendente https-response.txt "CA local indisponível: conf/tls/$ENV/ca.crt; HTTPS não foi alegado como aprovado."
fi

cat > "$OUT/README.md" <<EOF_README
# Evidências Fases 7–8

Coleta somente leitura feita para o projeto **$PROJETO**, ambiente **$ENV**,
com IP de teste informado explicitamente: **$IP_SITE**.

Os arquivos registram data UTC/local, revisão Git, versão do LXD, recursos do
host, listagens explícitas do projeto, redes, volumes, guests esperados,
monitoramento, limites sem carga e respostas HTTP/HTTPS. O HTTPS só é marcado
como aprovado quando a CA local está disponível e curl valida o certificado
sem modo inseguro; o corpo da página não é salvo.

Consulte **status.log** e **RESULTADO.txt** antes de compartilhar esta pasta ou
enviar qualquer parte ao GitHub. Eles podem conter nomes, endereços e estados
de infraestrutura. Senhas, variáveis de ambiente, configuração com segredos,
tokens de trust, certificados privados e chaves privadas não são coletados.
PENDENTE significa que a verificação não pôde ser feita (por exemplo, CA ou
container ausente); isso não deve ser apresentado como teste aprovado.
EOF_README
chmod 600 -- "$OUT/README.md"

if (( FAILURES == 0 )); then
  FINAL_STATUS=OK
elif (( PENDENTES > 0 && FAILURES == PENDENTES )); then
  FINAL_STATUS=PENDENTE
else
  FINAL_STATUS=FALHOU
fi
cat > "$OUT/RESULTADO.txt" <<EOF_RESULT
STATUS=$FINAL_STATUS
FALHAS=$FAILURES
PENDENTES=$PENDENTES
PROJETO=$PROJETO
AMBIENTE=$ENV
IP_SITE=$IP_SITE
REVISAO: confira status.log e todos os logs antes de compartilhar ou enviar ao GitHub.
EOF_RESULT
chmod 600 -- "$OUT/RESULTADO.txt"

printf 'Evidências gravadas em: %s\n' "$OUT"
printf 'Arquivos/status: %s/status.log e %s/RESULTADO.txt\n' "$OUT" "$OUT"
if (( FAILURES == 0 )); then
  printf 'Coleta concluída com STATUS=OK.\n'
else
  printf 'Coleta concluída com STATUS=%s; diagnósticos foram preservados.\n' "$FINAL_STATUS" >&2
fi
(( FAILURES == 0 ))
