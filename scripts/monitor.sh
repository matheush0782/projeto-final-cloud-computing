#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
Uso: monitor.sh [opções]

Opções:
  --once                 Executa uma amostra e termina.
  --interval N           Intervalo em segundos no modo contínuo (padrão: 5).
  --env prod|dev         Ambiente a monitorar (padrão: prod).
  --all                  Lista todas as instâncias do projeto selecionado.
  -h, --help, help       Mostra esta ajuda.

O projeto continua sendo escolhido por PROJETO (padrão: final-equipeN).
As consultas passam pelo lx() de common.sh e, portanto, não usam outros
projetos nem o remoto que não seja local.
EOF
}

ONCE=0
INTERVAL=5
ALL=0

while (($#)); do
  case "$1" in
    --once)
      ONCE=1
      ;;
    --interval)
      (($# >= 2)) || falhar '--interval exige um número inteiro positivo.'
      INTERVAL="$2"
      shift
      ;;
    --env)
      (($# >= 2)) || falhar '--env exige prod ou dev.'
      ENV="$2"
      shift
      ;;
    --all)
      ALL=1
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      falhar "Opção desconhecida: $1"
      ;;
  esac
  shift
done

[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || falhar '--interval deve ser um inteiro positivo.'

carregar_config
checar_lxd
exigir_comandos awk sleep timeout

lx_timeout() {
  local duracao="$1"
  shift
  timeout "$duracao" lxc --project="$PROJETO" "$@"
}

# O filtro é uma expressão regular ancorada. Os nomes vêm de common.sh, não da
# entrada de um usuário desconhecido; assim, app não casa com app-extra.
lista_filtro() {
  local nome separador='' filtro='^('
  for nome in "${INSTANCIAS[@]}"; do
    filtro+="${separador}${nome}"
    separador='|'
  done
  filtro+=')$'
  printf '%s' "$filtro"
}

LIST_CSV=''
fetch_list() {
  local -a args=(list -c ns4mDu --format=csv)
  local filtro

  if ((ALL == 0)); then
    filtro="$(lista_filtro)"
    args+=("$filtro")
  fi

  # A falha da listagem é fatal: sem ela, o monitor não pode alegar que viu
  # um estado atual. O stderr capturado é devolvido para diagnóstico.
  if ! LIST_CSV="$(lx "${args[@]}" 2>&1)"; then
    printf '%s\n' "$LIST_CSV" >&2
    falhar "Falha ao listar instâncias no projeto '$PROJETO'."
  fi
}

render_list() {
  LIST_CSV="$LIST_CSV" python3 - <<'PY'
import csv
import io
import os
import sys

try:
    rows = list(csv.reader(io.StringIO(os.environ.get("LIST_CSV", "")), strict=True))
except csv.Error as exc:
    print(f"CSV inválido retornado por lxc list: {exc}", file=sys.stderr)
    raise SystemExit(1)

clean = lambda value: value.strip() if value.strip() else "-"
rows = [row for row in rows if row]
if rows and rows[0][0].strip().upper() == "NAME":
    rows = rows[1:]

print(f"{'NAME':<20} {'STATE':<10} {'IPV4':<18} {'MEMORY':>12} {'DISK':>12} {'CPU_SECONDS':>14}")
print("-" * 91)
if not rows:
    print("(nenhuma instância selecionada neste projeto)")

for row in rows:
    if len(row) < 6:
        print("Resposta CSV sem as seis colunas esperadas (n,s,4,m,D,u).", file=sys.stderr)
        raise SystemExit(1)
    name, state, ipv4, memory, disk, cpu = (clean(value) for value in row[:6])
    print(f"{name:<20.20} {state:<10.10} {ipv4:<18.18} {memory:>12.12} {disk:>12.12} {cpu:>14.14}")
PY
}

selected_names() {
  LIST_CSV="$LIST_CSV" python3 - <<'PY'
import csv
import io
import os
import sys

try:
    rows = list(csv.reader(io.StringIO(os.environ.get("LIST_CSV", "")), strict=True))
except csv.Error as exc:
    print(f"CSV inválido retornado por lxc list: {exc}", file=sys.stderr)
    raise SystemExit(1)

for row in rows:
    if row and row[0].strip().upper() != "NAME":
        print(row[0].strip())
PY
}

running_names() {
  LIST_CSV="$LIST_CSV" python3 - <<'PY'
import csv
import io
import os
import sys

try:
    rows = list(csv.reader(io.StringIO(os.environ.get("LIST_CSV", "")), strict=True))
except csv.Error as exc:
    print(f"CSV inválido retornado por lxc list: {exc}", file=sys.stderr)
    raise SystemExit(1)

for row in rows:
    if len(row) >= 2 and row[0].strip().upper() != "NAME":
        if row[1].strip().upper() == "RUNNING":
            print(row[0].strip())
PY
}

is_expected_guest() {
  local candidato="$1" nome
  for nome in "${INSTANCIAS[@]}"; do
    [[ "$nome" == "$candidato" ]] && return 0
  done
  return 1
}

guest_df() {
  local nome="$1" saida
  # Só os três papéis previstos recebem uma consulta interna, mesmo com
  # --all. A consulta é bounded para não travar o loop se o guest não responde.
  # A variável path deve expandir no guest, não neste shell do host.
  # shellcheck disable=SC2016
  if ! saida="$(lx_timeout 5s exec "$nome" -- sh -c '
    printf "PATH            SIZE  USED AVAIL USE%%\n"
    df -hP /
    for path in /var/www/html/wp-content/uploads /var/lib/mysql; do
      if [ -e "$path" ]; then
        df -hP "$path"
      fi
    done
  ' 2>&1)"; then
    log "Aviso: df dentro de '$nome' indisponível ou expirou: ${saida:-sem detalhes}."
    return 0
  fi
  printf 'Guest df (%s):\n%s\n' "$nome" "$saida"
}

filter_metrics() {
  # O endpoint retorna texto no formato Prometheus. Filtrar em Python evita
  # casar nomes por substring e também permite validar labels escapados.
  python3 -c '
import re
import sys

project, env, allowed_arg = sys.argv[1:4]
allowed = {name for name in allowed_arg.splitlines() if name}
label_re = re.compile(r"([a-zA-Z_][a-zA-Z0-9_]*)=\"((?:\\\\.|[^\"\\\\])*)\"")
metric_names = {"lxd_cpu_seconds_total", "lxd_memory_MemAvailable_bytes", "lxd_filesystem_avail_bytes"}
emitted = 0

for line in sys.stdin.read().splitlines():
    if not line or line.startswith("#") or "{" not in line or "}" not in line:
        continue
    start = line.find("{")
    if line[:start] not in metric_names:
        continue
    end = line.rfind("}")
    labels = {}
    for match in label_re.finditer(line[start + 1:end]):
        value = re.sub(r"\\\\(.)", r"\\1", match.group(2))
        labels[match.group(1)] = value
    if labels.get("project") != project:
        continue
    if labels.get("name") not in allowed:
        continue
    if "env" in labels and labels["env"] != env:
        continue
    if "environment" in labels and labels["environment"] != env:
        continue
    print(line)
    emitted += 1
    if emitted >= 12:
        break
' "$1" "$2" "$3"
}

show_metrics() {
  local selected="$1" raw filtered

  # O parâmetro project é explícito mesmo com --project no wrapper lx(). A
  # indisponibilidade do endpoint é informativa, não invalida a listagem.
  if ! raw="$(lxc query "/1.0/metrics?project=${PROJETO}" 2>&1)"; then
    log "Aviso: endpoint /1.0/metrics indisponível para '$PROJETO'; seguindo sem métricas."
    return 0
  fi
  if ! filtered="$(filter_metrics "$PROJETO" "$ENV" "$selected" <<< "$raw")"; then
    log 'Aviso: resposta de métricas não pôde ser filtrada; seguindo sem métricas.'
    return 0
  fi
  if [[ -n "$filtered" ]]; then
    printf 'Métricas Prometheus filtradas (project=%s env=%s):\n%s\n' "$PROJETO" "$ENV" "$filtered"
  else
    log "Aviso: endpoint respondeu, mas não há amostras para as instâncias permitidas de '$ENV'."
  fi
}

run_once() {
  local formatted selected running nome

  log "Amostra: projeto=$PROJETO ambiente=$ENV modo=$([[ $ALL -eq 1 ]] && printf all || printf allowlist)"
  fetch_list

  if ! formatted="$(render_list)"; then
    falhar 'Não foi possível interpretar a resposta CSV de lxc list.'
  fi
  printf '%s\n' "$formatted"

  if ! selected="$(selected_names)"; then
    falhar 'Não foi possível obter os nomes selecionados da resposta de lxc list.'
  fi
  if ! running="$(running_names)"; then
    falhar 'Não foi possível obter os estados da resposta de lxc list.'
  fi

  if [[ -n "$running" ]]; then
    while IFS= read -r nome; do
      [[ -n "$nome" ]] || continue
      if is_expected_guest "$nome"; then
        guest_df "$nome"
      fi
    done <<< "$running"
  fi

  show_metrics "$selected"
}

if ((ONCE)); then
  run_once
else
  while :; do
    if [[ -t 1 && -n "${TERM:-}" ]]; then printf '\033[2J\033[H'; fi
    run_once
    sleep "$INTERVAL"
  done
fi
