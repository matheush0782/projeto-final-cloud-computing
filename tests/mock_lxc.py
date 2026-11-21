#!/usr/bin/env python3
"""LXC falso usado exclusivamente pelos testes; nunca opera infraestrutura real."""
import json
import os
import re
import sys
from pathlib import Path

import yaml

state_path = Path(os.environ["MOCK_STATE"])
state = json.loads(state_path.read_text())
state.setdefault("log", [])
state.setdefault("projects", {})
state.setdefault("instances", {})
state.setdefault("profiles", {})
state.setdefault("networks", {})
state.setdefault("pools", {})
state.setdefault("volumes", {})

raw_args = sys.argv[1:]
project = "default"
args = []
for arg in raw_args:
    if arg.startswith("--project="):
        project = arg.split("=", 1)[1]
    else:
        args.append(arg)

a = args
state["log"].append({"project": project, "args": a})


def save() -> None:
    state_path.write_text(json.dumps(state))


def result(value=None, code=0) -> None:
    save()
    if value is not None:
        print(json.dumps(value) if isinstance(value, (dict, list)) else value)
    sys.exit(code)


def instance_key(name: str) -> str:
    return f"{project}/{name}"


def parse_options(items):
    options = {}
    for item in items:
        if "=" in item and not item.startswith("--"):
            key, value = item.split("=", 1)
            options[key] = value
    return options


if state.get("fail_on") and a[: len(state["fail_on"])] == state["fail_on"]:
    result("Falha simulada de API/permissão", 1)

if a == ["remote", "get-default"]:
    result(state.get("remote", "local"))

if a[:1] == ["info"]:
    name = a[1] if len(a) > 1 else ""
    if name == "local:":
        result("LXD MOCK — não é VM real")
    if instance_key(name) not in state["instances"]:
        result("Instância ausente", 1)
    result(f"Name: {name}\nStatus: Running")

if a[:2] == ["project", "list"]:
    result([{"name": name, "config": cfg} for name, cfg in state["projects"].items()])

if a[:2] == ["project", "get"]:
    if a[2] not in state["projects"]:
        result("Projeto ausente", 1)
    result(state["projects"][a[2]].get(a[3], ""))

if a[:2] == ["project", "create"]:
    cfg = {}
    for i, arg in enumerate(a):
        if arg == "-c" and i + 1 < len(a):
            key, value = a[i + 1].split("=", 1)
            cfg[key] = value
    state["projects"][a[2]] = cfg
    result()

if a[:2] == ["network", "list"]:
    result(list(state["networks"].values()))

if a[:2] == ["network", "create"]:
    state["networks"][a[2]] = {
        "name": a[2],
        "type": "bridge",
        "managed": True,
        "config": dict(v.split("=", 1) for v in a[3:] if "=" in v),
    }
    result()

if a[:2] == ["storage", "list"]:
    result(list(state["pools"].values()))

if a[:2] == ["storage", "create"]:
    state["pools"][a[2]] = {"name": a[2], "driver": a[3]}
    result()

if a[:3] == ["storage", "volume", "list"]:
    pool = a[3]
    result([v for v in state["volumes"].values() if v["project"] == project and v["pool"] == pool])

if a[:3] == ["storage", "volume", "create"]:
    pool, name = a[3], a[4]
    key = f"{project}/{name}"
    state["volumes"][key] = {
        "name": name,
        "type": "custom",
        "project": project,
        "pool": pool,
        "used_by": [],
    }
    result()

if a[:3] == ["storage", "volume", "delete"]:
    key = f"{project}/{a[4]}"
    volume = state["volumes"].get(key)
    if volume is None:
        result("Volume ausente", 1)
    if volume.get("used_by"):
        result("Volume em uso", 1)
    del state["volumes"][key]
    result()

if a[:2] == ["profile", "list"]:
    result(list(state["profiles"].values()))

if a[:2] == ["profile", "create"]:
    name = a[2]
    state["profiles"][name] = {"name": name, "config": {}, "devices": {}, "used_by": []}
    result()

if a[:2] == ["profile", "edit"]:
    profile = yaml.safe_load(sys.stdin.read()) or {}
    profile["name"] = a[2]
    profile["used_by"] = []
    state["profiles"][a[2]] = profile
    result()

if a and a[0] == "list":
    instances = [i for i in state["instances"].values() if i["project"] == project]
    filters = []
    skip = False
    for arg in a[1:]:
        if skip:
            skip = False
            continue
        if arg in ("-c", "--columns"):
            skip = True
            continue
        if not arg.startswith("-"):
            filters.append(arg)
    if filters:
        instances = [i for i in instances if all(re.search(pattern, i["name"]) for pattern in filters)]
    if "--format=json" in a:
        result(instances)
    if "--format=csv" in a:
        result(
            "\n".join(
                ",".join(
                    [
                        i["name"],
                        i["status"].upper(),
                        "10.10.10.11 (eth0)",
                        "100MiB",
                        "1GiB",
                        "15",
                    ]
                )
                for i in instances
            )
        )
    result("\n".join(i["name"] + " " + i["status"] + " MOCK" for i in instances))

if a and a[0] == "init":
    name = a[2]
    config = {}
    for i, arg in enumerate(a):
        if arg == "-p" and i + 1 < len(a):
            config.update(state["profiles"].get(a[i + 1], {}).get("config", {}))
    state["instances"][instance_key(name)] = {
        "name": name,
        "project": project,
        "status": "Stopped",
        "expanded_config": config,
        "devices": {},
    }
    result()

if a and a[0] == "start":
    key = instance_key(a[1])
    if key not in state["instances"]:
        result("Instância ausente", 1)
    state["instances"][key]["status"] = "Running"
    result()

if a[:3] in (["config", "device", "add"], ["config", "device", "override"]):
    operation = a[2]
    name, device = a[3], a[4]
    key = instance_key(name)
    if key not in state["instances"]:
        result("Instância ausente", 1)
    devices = state["instances"][key].setdefault("devices", {})
    if operation == "add":
        if device in devices:
            result(f"Dispositivo já existe: {device}", 1)
        if len(a) < 6:
            result("Tipo do dispositivo ausente", 1)
        options = {"type": a[5]}
        options.update(parse_options(a[6:]))
        devices[device] = options
    else:
        options = devices.get(device, {}).copy()
        options.update(parse_options(a[5:]))
        devices[device] = options
    options = devices[device]
    if "source" in options:
        volume = state["volumes"].get(f"{project}/{options['source']}")
        if volume is None:
            result("Volume ausente", 1)
        ref = f"/1.0/instances/{name}?project={project}"
        if ref not in volume.setdefault("used_by", []):
            volume["used_by"].append(ref)
    result()

if a[:3] == ["config", "device", "list"]:
    key = instance_key(a[3])
    if key not in state["instances"]:
        result("Instância ausente", 1)
    result("\n".join(state["instances"][key].get("devices", {})))

if a[:3] == ["config", "device", "get"]:
    key = instance_key(a[3])
    device = state["instances"].get(key, {}).get("devices", {}).get(a[4])
    if device is None:
        result("Dispositivo ausente", 1)
    if len(a) < 6 or a[5] not in device:
        result("Campo ausente", 1)
    result(device[a[5]])

if a[:3] == ["config", "device", "set"]:
    key = instance_key(a[3])
    device = state["instances"].get(key, {}).get("devices", {}).get(a[4])
    if device is None:
        result("Dispositivo ausente", 1)
    device.update(parse_options(a[5:]))
    result()

if a[:2] == ["config", "show"]:
    key = instance_key(a[2])
    if key not in state["instances"]:
        result("Instância ausente", 1)
    result(state["instances"][key])

if a[:2] == ["config", "get"]:
    key = instance_key(a[2])
    result(state["instances"][key].get("expanded_config", {}).get(a[3], ""))

if a[:2] == ["file", "push"]:
    if len(a) < 3 or not Path(a[2]).is_file():
        result("Arquivo local ausente", 1)
    # --mode e o destino são aceitos e registrados, mas nenhum guest é tocado.
    result()

if a and a[0] == "delete":
    names = [item for item in a[1:] if not item.startswith("-")]
    if not names:
        result("Nome da instância ausente", 1)
    key = instance_key(names[0])
    if key not in state["instances"]:
        result("Instância ausente", 1)
    del state["instances"][key]
    for volume in state["volumes"].values():
        ref = f"/1.0/instances/{names[0]}?project={project}"
        volume["used_by"] = [item for item in volume.get("used_by", []) if item != ref]
    result()

if a and a[0] == "query":
    if len(a) > 1 and "/metrics" in a[1]:
        rows = []
        for instance in state["instances"].values():
            rows.extend(
                [
                    f'lxd_cpu_seconds_total{{name="{instance["name"]}",project="{instance["project"]}",cpu="0",mode="user"}} 15',
                    f'lxd_memory_MemAvailable_bytes{{name="{instance["name"]}",project="{instance["project"]}"}} 120000000',
                    f'lxd_filesystem_avail_bytes{{name="{instance["name"]}",project="{instance["project"]}",mountpoint="/"}} 8000000000',
                ]
            )
        result("\n".join(rows))
    if len(a) > 1 and "/instances/" in a[1]:
        name = a[1].split("/instances/", 1)[1].split("?", 1)[0].split("/", 1)[0]
        key = instance_key(name)
        if key not in state["instances"]:
            result("Instância ausente", 1)
        result(state["instances"][key])

if a and a[0] == "exec":
    name = a[1]
    command = a[a.index("--") + 1 :] if "--" in a else []
    if instance_key(name) not in state["instances"]:
        result("Instância ausente", 1)
    if command[:2] == ["sh", "-c"] and "NPROC=" in command[2]:
        config = state["instances"][instance_key(name)]["expanded_config"]
        memory = config["limits.memory"]
        number = int(re.search(r"\d+", memory).group())
        memory_bytes = number * (1024**3 if "GiB" in memory else 1024**2)
        memory_bytes = state.get("probe_memory", memory_bytes)
        result(
            f"NPROC=1\nFREE_MB={memory_bytes // 1024**2}\nCGROUP_VERSION=2\n"
            f"MEMORY_LIMIT_BYTES={memory_bytes}\nCPUSET=0"
        )
    if command[:2] == ["sh", "-c"] and "df -hP" in command[2]:
        result("Filesystem Size Used Avail Use% Mounted on\nmock 40G 10G 30G 25% /")
    if command[:1] == ["nproc"]:
        result("1")
    if command[:2] == ["free", "-m"]:
        result("              total used free shared buff/cache available\nMem:            512  100  300  0  112  0\nSwap:             0    0    0")
    if command[:2] == ["df", "-h"]:
        result("Filesystem Size Used Avail Use% Mounted on\nmock 40G 10G 30G 25% /")
    if command[:1] == ["cat"] and "memory" in " ".join(command):
        result("536870912")
    if command[:1] == ["timeout"]:
        result(code=124)
    if command[:2] == ["bash", "-s"]:
        sys.stdin.read()
    # Scripts/configuração PHP e comandos de serviço do guest não são executados.
    result()

result("Comando não implementado pelo mock: " + repr(a), 2)
