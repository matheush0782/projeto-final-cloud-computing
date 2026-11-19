#!/usr/bin/env python3
"""LXC falso: usado SOMENTE nos testes; não executa operações de infraestrutura."""
import json
import os
import re
import sys
from pathlib import Path
import yaml

path = Path(os.environ['MOCK_STATE'])
state = json.loads(path.read_text())
args = sys.argv[1:]
project = 'default'
args2 = []
for arg in args:
    if arg.startswith('--project='):
        project = arg.split('=', 1)[1]
    else:
        args2.append(arg)
a = args2
state['log'].append({'project': project, 'args': a})

def save():
    path.write_text(json.dumps(state))

def result(value=None, code=0):
    save()
    if value is not None:
        print(json.dumps(value) if isinstance(value, (dict, list)) else value)
    sys.exit(code)

if state.get('fail_on') and a[:len(state['fail_on'])] == state['fail_on']:
    result('Falha simulada de API/permissão', 1)
if a == ['remote', 'get-default']:
    result(state.get('remote', 'local'))
if a == ['info', 'local:']:
    result('LXD MOCK — não é VM real')
if a[:2] == ['project', 'list']:
    result([{'name': name, 'config': cfg} for name, cfg in state['projects'].items()])
if a[:2] == ['project', 'get']:
    result(state['projects'][a[2]].get(a[3], ''))
if a[:2] == ['project', 'create']:
    cfg = {}
    for i, arg in enumerate(a):
        if arg == '-c':
            k, v = a[i+1].split('=', 1); cfg[k] = v
    state['projects'][a[2]] = cfg; result()
if a[:2] == ['network', 'list']:
    result(list(state['networks'].values()))
if a[:2] == ['network', 'create']:
    state['networks'][a[2]] = {'name': a[2], 'type': 'bridge', 'managed': True, 'config': dict(v.split('=', 1) for v in a[3:])}
    result()
if a[:2] == ['storage', 'list']:
    result(list(state['pools'].values()))
if a[:2] == ['storage', 'create']:
    state['pools'][a[2]] = {'name': a[2], 'driver': a[3]}; result()
if a[:3] == ['storage', 'volume', 'list']:
    result([v for v in state['volumes'].values() if v['project'] == project and v['pool'] == a[3]])
if a[:3] == ['storage', 'volume', 'create']:
    key = project + '/' + a[4]
    state['volumes'][key] = {'name': a[4], 'type': 'custom', 'project': project, 'pool': a[3], 'used_by': []}; result()
if a[:3] == ['storage', 'volume', 'delete']:
    key = project + '/' + a[4]
    if state['volumes'][key]['used_by']:
        result('Volume em uso', 1)
    del state['volumes'][key]; result()
if a[:2] == ['profile', 'list']:
    result(list(state['profiles'].values()))
if a[:2] == ['profile', 'create']:
    state['profiles'][a[2]] = {'name': a[2], 'config': {}, 'devices': {}, 'used_by': []}; result()
if a[:2] == ['profile', 'edit']:
    p = yaml.safe_load(sys.stdin.read()); p['name'] = a[2]; p['used_by'] = []
    state['profiles'][a[2]] = p; result()
if a[0] == 'list':
    inst = [i for i in state['instances'].values() if i['project'] == project]
    filters = []
    skip = False
    for arg in a[1:]:
        if skip: skip = False; continue
        if arg in ('-c', '--columns'): skip = True; continue
        if not arg.startswith('-'): filters.append(arg)
    if filters:
        inst = [i for i in inst if all(re.search(f, i['name']) for f in filters)]
    if '--format=json' in a: result(inst)
    if '--format=csv' in a:
        result('\n'.join(','.join([i['name'], i['status'].upper(), '10.10.10.11 (eth0)', '100MiB', '1GiB', '15']) for i in inst))
    result('\n'.join(i['name'] + ' ' + i['status'] + ' MOCK' for i in inst))
if a[0] == 'init':
    name = a[2]
    cfg = {}
    for i, arg in enumerate(a):
        if arg == '-p': cfg.update(state['profiles'][a[i+1]].get('config', {}))
    state['instances'][project+'/'+name] = {'name': name, 'project': project, 'status': 'Stopped', 'expanded_config': cfg, 'devices': {}}
    result()
if a[0] == 'start':
    state['instances'][project+'/'+a[1]]['status'] = 'Running'; result()
if a[:3] == ['config', 'device', 'add'] or a[:3] == ['config', 'device', 'override']:
    name, device = a[3:5]
    start = 6 if a[2] == 'add' else 5
    opts = dict(v.split('=', 1) for v in a[start:])
    state['instances'][project+'/'+name]['devices'][device] = opts
    if 'source' in opts:
        v = state['volumes'][project+'/'+opts['source']]
        v['used_by'].append('/1.0/instances/'+name+'?project='+project)
    result()
if a[:2] == ['config', 'show']:
    result(state['instances'][project+'/'+a[2]])
if a[:2] == ['config', 'get']:
    result(state['instances'][project+'/'+a[2]]['expanded_config'].get(a[3], ''))
if a[:2] == ['file', 'push']:
    if not Path(a[2]).is_file(): result('Arquivo local ausente', 1)
    result()
if a[0] == 'delete':
    name = next(x for x in a[1:] if not x.startswith('-'))
    del state['instances'][project+'/'+name]
    for v in state['volumes'].values():
        v['used_by'] = [x for x in v['used_by'] if x != '/1.0/instances/'+name+'?project='+project]
    result()
if a[0] == 'query':
    if '/metrics' in a[1]:
        rows = []
        for i in state['instances'].values():
            rows += [f'lxd_cpu_seconds_total{{name="{i["name"]}",project="{i["project"]}",cpu="0",mode="user"}} 15',
                     f'lxd_memory_MemAvailable_bytes{{name="{i["name"]}",project="{i["project"]}"}} 120000000',
                     f'lxd_filesystem_avail_bytes{{name="{i["name"]}",project="{i["project"]}",mountpoint="/"}} 8000000000']
        result('\n'.join(rows))
    if '/instances/' in a[1]:
        name = a[1].split('/instances/',1)[1].split('?',1)[0].split('/',1)[0]
        result(state['instances'][project+'/'+name])
if a[0] == 'exec':
    name = a[1]; cmd = a[a.index('--')+1:]
    if project+'/'+name not in state['instances']: result('Instância ausente', 1)
    if cmd[:2] == ['sh', '-c'] and 'NPROC=' in cmd[2]:
        cfg = state['instances'][project+'/'+name]['expanded_config']
        memory = cfg['limits.memory']
        number = int(re.search(r'\d+', memory).group())
        mem_bytes = number * (1024**3 if 'GiB' in memory else 1024**2)
        mem_bytes = state.get('probe_memory', mem_bytes)
        result(f'NPROC=1\nFREE_MB={mem_bytes//1024**2}\nCGROUP_VERSION=2\nMEMORY_LIMIT_BYTES={mem_bytes}\nCPUSET=0')
    if cmd[:2] == ['sh', '-c'] and 'df -hP' in cmd[2]: result('Filesystem Size Used Avail Use% Mounted on\nmock 40G 10G 30G 25% /')
    if cmd[:1] == ['nproc']: result('1')
    if cmd[:2] == ['free', '-m']: result('              total used free shared buff/cache available\nMem:            512  100  300  0  112  400\nSwap:             0    0    0')
    if cmd[:2] == ['df', '-h']: result('Filesystem Size Used Avail Use% Mounted on\nmock 40G 10G 30G 25% /')
    if cmd[:1] == ['cat'] and 'memory' in ' '.join(cmd): result('536870912')
    if cmd[:1] == ['timeout']: result(code=124)
    if cmd[:2] == ['bash', '-s']: sys.stdin.read()
    # Scripts de configuração dentro dos guests NÃO são executados no mock.
    result()
result('Comando não implementado pelo mock: '+repr(a), 2)
