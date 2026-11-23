#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
Uso: test-limits.sh [opções]

Opções:
  --env prod|dev         Ambiente a testar (padrão: prod).
  --load                 Carga de CPU opt-in em dev-app, guest 20 s/host 30 s.
  -h, --help, help       Mostra esta ajuda.

PROJETO escolhe o projeto LXD (padrão: final-equipeN). O teste usa somente
as instâncias esperadas em INSTANCIAS, com configuração expanded_config.
A carga opcional usa somente dev-app, não aloca memória, não instala pacotes
e considera retorno 124 do timeout no guest como o resultado esperado.
EOF
}

LOAD=0

while (($#)); do
  case "$1" in
    --env)
      (($# >= 2)) || falhar '--env exige prod ou dev.'
      ENV="$2"
      shift
      ;;
    --load)
      LOAD=1
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

carregar_config
checar_lxd
exigir_comandos awk timeout

lx_timeout() {
  local duracao="$1"
  shift
  timeout "$duracao" lxc --project="$PROJETO" "$@"
}

if ((LOAD)) && [[ "$ENV" != dev ]]; then
  falhar '--load é permitido somente com --env dev para não gerar carga em produção.'
fi

# Converte a forma de limits.cpu ("1", "0-1" ou "0,2") e limits.memory
# para números comparáveis, preservando os valores textuais para o relatório.
read_limits() {
  python3 -c '
import json
import re
import sys

obj = json.load(sys.stdin)
if not isinstance(obj, dict):
    raise SystemExit("resposta da API de instância não é um objeto JSON")
metadata = obj.get("metadata", obj)
if not isinstance(metadata, dict):
    raise SystemExit("metadata da resposta da API de instância não é um objeto JSON")
cfg = metadata.get("expanded_config")
if not isinstance(cfg, dict):
    raise SystemExit("expanded_config não está presente na resposta da API de instância")
cpu_raw = str(cfg.get("limits.cpu", "")).strip()
mem_raw = str(cfg.get("limits.memory", "")).strip()

if not cpu_raw:
    raise SystemExit("limits.cpu não está presente na configuração expandida")
if not mem_raw:
    raise SystemExit("limits.memory não está presente na configuração expandida")

if re.fullmatch(r"[0-9]+", cpu_raw):
    cpu_count = int(cpu_raw)
else:
    cpu_count = 0
    for token in cpu_raw.split(","):
        token = token.strip()
        if re.fullmatch(r"[0-9]+-[0-9]+", token):
            first, last = (int(part) for part in token.split("-", 1))
            if last < first:
                raise SystemExit("intervalo inválido em limits.cpu")
            cpu_count += last - first + 1
        elif re.fullmatch(r"[0-9]+", token):
            cpu_count += 1
        else:
            raise SystemExit("limits.cpu não é uma contagem nem uma lista de CPUs")
if cpu_count <= 0:
    raise SystemExit("limits.cpu deve representar pelo menos uma CPU")

match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)\s*([kmgtpe]i?b)?", mem_raw, re.I)
if not match:
    raise SystemExit("limits.memory não tem unidade reconhecida")
number = float(match.group(1))
unit = (match.group(2) or "B").upper()
factors = {
    "B": 1,
    "KB": 1000, "MB": 1000**2, "GB": 1000**3, "TB": 1000**4,
    "KIB": 1024, "MIB": 1024**2, "GIB": 1024**3, "TIB": 1024**4,
}
if unit not in factors:
    raise SystemExit("unidade de limits.memory não suportada")
memory_bytes = int(number * factors[unit])
if memory_bytes <= 0:
    raise SystemExit("limits.memory deve ser positivo")

print(f"{cpu_count}\t{memory_bytes}\t{cpu_raw}\t{mem_raw}")
'
}

state_of() {
  local nome="$1" raw
  if ! raw="$(lx list -c ns --format=json "^${nome}$" 2>&1)"; then
    printf '%s\n' "$raw" >&2
    return 1
  fi
  python3 -c '
import json
import sys
items = json.load(sys.stdin)
if len(items) != 1:
    print("MISSING")
else:
    item = items[0]
    state = item.get("status")
    if not state and isinstance(item.get("state"), dict):
        state = item["state"].get("status")
    print(str(state or "UNKNOWN").upper())
' <<< "$raw"
}

probe_key() {
  local key="$1" data="$2"
  awk -F= -v wanted="$key" '
    $1 == wanted { sub(/^[^=]*=/, ""); print; found=1; exit }
    END { if (!found) exit 1 }
  ' <<< "$data"
}

PROBE_SCRIPT="$(cat <<'SH'
set -u
printf 'NPROC='
nproc
printf 'FREE_MB='
free -m | awk '$1 == "Mem:" { print $2 }'
printf 'CGROUP_VERSION='
if [ -r /sys/fs/cgroup/memory.max ]; then
  printf '2\nMEMORY_LIMIT_BYTES='
  cat /sys/fs/cgroup/memory.max
  printf 'CPUSET='
  if [ -r /sys/fs/cgroup/cpuset.cpus.effective ]; then
    cat /sys/fs/cgroup/cpuset.cpus.effective
  elif [ -r /sys/fs/cgroup/cpuset.cpus ]; then
    cat /sys/fs/cgroup/cpuset.cpus
  else
    printf 'UNAVAILABLE'
  fi
  printf '\n'
elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
  printf '1\nMEMORY_LIMIT_BYTES='
  cat /sys/fs/cgroup/memory/memory.limit_in_bytes
  printf 'CPUSET='
  if [ -r /sys/fs/cgroup/cpuset/cpuset.cpus ]; then
    cat /sys/fs/cgroup/cpuset/cpuset.cpus
  elif [ -r /sys/fs/cgroup/cpuset/cpuset.cpus.effective ]; then
    cat /sys/fs/cgroup/cpuset/cpuset.cpus.effective
  else
    printf 'UNAVAILABLE'
  fi
  printf '\n'
else
  printf 'unknown\nMEMORY_LIMIT_BYTES=UNAVAILABLE\nCPUSET=UNAVAILABLE\n'
fi
SH
)"

validate_probe() {
  python3 - "$@" <<'PY'
import sys

expected_cpu = int(sys.argv[1])
expected_memory = int(sys.argv[2])
actual_nproc = int(sys.argv[3])
actual_free_mb = int(sys.argv[4])
cgroup_version = sys.argv[5]
cgroup_limit = sys.argv[6]
cpuset = sys.argv[7]
errors = []

if actual_nproc != expected_cpu:
    errors.append(f"nproc={actual_nproc}, esperado={expected_cpu} de limits.cpu")

if cgroup_version not in {"1", "2"}:
    errors.append("cgroup de memória não identificado (esperado v2 ou fallback v1)")

try:
    cgroup_bytes = int(cgroup_limit)
except ValueError:
    cgroup_bytes = 0
    errors.append(f"memory.limit do cgroup inválido: {cgroup_limit}")

# O limite do cgroup deve ser próximo da configuração; 1 MiB cobre arredondamento
# de página/runtime sem mascarar uma divergência de limite.
tolerance_bytes = 1 * 1024 * 1024
if cgroup_bytes <= 0 or abs(cgroup_bytes - expected_memory) > tolerance_bytes:
    errors.append(
        f"memory cgroup={cgroup_limit} bytes, esperado próximo de {expected_memory} bytes"
    )

expected_mb = expected_memory // (1024 * 1024)
tolerance_mb = max(1, expected_mb * 15 // 100)
if actual_free_mb <= 0 or abs(actual_free_mb - expected_mb) > tolerance_mb:
    errors.append(
        f"free -m total={actual_free_mb} MiB, esperado próximo de {expected_mb} MiB"
    )

def cpuset_count(spec):
    spec = spec.strip()
    if not spec or spec == "UNAVAILABLE":
        return None
    total = 0
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            first, last = (int(value) for value in part.split("-", 1))
            if last < first:
                raise ValueError("intervalo invertido")
            total += last - first + 1
        else:
            int(part)
            total += 1
    return total

try:
    actual_cpuset = cpuset_count(cpuset)
except (TypeError, ValueError):
    actual_cpuset = None
    errors.append(f"cpuset inválido: {cpuset}")
if actual_cpuset is None:
    errors.append("cpuset não está disponível para contar CPUs")
elif actual_cpuset != expected_cpu:
    errors.append(f"cpuset={actual_cpuset}, esperado={expected_cpu} CPU(s)")

if errors:
    print("; ".join(errors))
    raise SystemExit(1)

print(
    f"OK nproc={actual_nproc} cpuset={cpuset} ({expected_cpu} CPU(s)); "
    f"free -m total={actual_free_mb} MiB; cgroup-v{cgroup_version}="
    f"{cgroup_limit} bytes"
)
PY
}

record_failure() {
  log "FALHA: $*"
  FAILURES=$((FAILURES + 1))
}

FAILURES=0
TESTED=()

for nome in "${INSTANCIAS[@]}"; do
  log "Testando limites expandidos de '$nome' no projeto '$PROJETO'."

  if ! config_json="$(lx_timeout 5s query "/1.0/instances/${nome}?project=${PROJETO}" 2>&1)"; then
    record_failure "$nome: não foi possível consultar expanded_config: $config_json"
    continue
  fi
  if ! limits="$(read_limits <<< "$config_json")"; then
    record_failure "$nome: não foi possível interpretar limits.cpu/limits.memory expandidos."
    continue
  fi
  IFS=$'\t' read -r cpu_expected memory_expected cpu_raw memory_raw <<< "$limits"

  if ! state="$(state_of "$nome")"; then
    record_failure "$nome: falha ao consultar o estado no projeto '$PROJETO'."
    continue
  fi
  if [[ "$state" != RUNNING ]]; then
    record_failure "$nome: estado '$state'; é necessário RUNNING para testar o guest."
    continue
  fi

  if ! probe="$(lx_timeout 5s exec "$nome" -- sh -c "$PROBE_SCRIPT" 2>&1)"; then
    record_failure "$nome: probe de nproc/free/cgroup falhou ou expirou: $probe"
    continue
  fi

  if ! actual_nproc="$(probe_key NPROC "$probe")" || \
     ! actual_free_mb="$(probe_key FREE_MB "$probe")" || \
     ! cgroup_version="$(probe_key CGROUP_VERSION "$probe")" || \
     ! cgroup_limit="$(probe_key MEMORY_LIMIT_BYTES "$probe")" || \
     ! cpuset="$(probe_key CPUSET "$probe")"; then
    record_failure "$nome: saída do probe não contém todas as chaves esperadas."
    continue
  fi

  if ! validation="$(validate_probe "$cpu_expected" "$memory_expected" "$actual_nproc" "$actual_free_mb" "$cgroup_version" "$cgroup_limit" "$cpuset")"; then
    record_failure "$nome: $validation (config CPU=$cpu_raw memória=$memory_raw)"
    continue
  fi
  log "$nome: $validation (config CPU=$cpu_raw memória=$memory_raw)"
  TESTED+=("$nome")
done

if ((FAILURES)); then
  log "$FAILURES instância(s) não passaram nas verificações; carga opcional não será executada."
  exit 1
fi

if ((LOAD)); then
  log "Carga de CPU opt-in somente em 'dev-app' por 20 s; guard do host em 30 s; nenhum buffer de memória é alocado."
  set +e
  # A shell string é deliberadamente executada no guest, não expandida no host.
  # shellcheck disable=SC2016
  lx_timeout 30s exec dev-app -- timeout 20s sh -c 'yes > /dev/null' >/dev/null 2>&1
  rc=$?
  set -e
  if ((rc == 124)); then
    log "dev-app: timeout 124 recebido como esperado após 20 s no guest."
  else
    record_failure "dev-app: carga terminou com código $rc; 124 era o resultado esperado."
  fi
fi

if ((FAILURES)); then
  falhar "$FAILURES falha(s) nas verificações de limites."
fi

log 'Todos os limites selecionados foram verificados.'
