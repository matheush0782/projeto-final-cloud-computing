#!/usr/bin/env python3
"""Testes de fluxo com LXC falso. Não substituem validação na VM."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROJECT = 'final-equipeN'
FEATURES = {'features.images':'false', 'features.profiles':'false', 'features.networks':'false', 'features.storage.volumes':'true'}

class ScriptsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.state = self.base / 'state.json'
        self.state.write_text(json.dumps({'projects':{}, 'instances':{}, 'profiles':{}, 'networks':{}, 'pools':{}, 'volumes':{}, 'log':[]}))
        bin_dir = self.base / 'bin'; bin_dir.mkdir()
        shutil.copy(ROOT/'tests/mock_lxc.py', bin_dir/'lxc')
        (bin_dir/'lxc').chmod(0o755)
        self.env = dict(os.environ, PATH=str(bin_dir)+os.pathsep+os.environ['PATH'], MOCK_STATE=str(self.state), PROJETO=PROJECT, POOL='pool-final', ENV='prod', DB_PASS='SenhaMock123', VM_HOST='127.0.0.1')
    def tearDown(self): self.tmp.cleanup()
    def read(self): return json.loads(self.state.read_text())
    def write(self, obj): self.state.write_text(json.dumps(obj))
    def run_script(self, script, *args, env=None, success=True):
        result = subprocess.run(['bash',str(ROOT/'scripts'/script),*args], env={**self.env,**(env or {})}, capture_output=True, text=True, timeout=40, stdin=subprocess.DEVNULL)
        if success: self.assertEqual(result.returncode,0,result.stdout+'\n'+result.stderr)
        else: self.assertNotEqual(result.returncode,0,result.stdout+'\n'+result.stderr)
        return result
    def seed(self):
        self.run_script('deploy.sh','--http-only')
        self.run_script('deploy.sh','--http-only',env={'ENV':'dev'})
    def test_mariadb_binds_to_environment_db_address(self):
        script = (ROOT / 'conf' / 'config-mariadb.sh').read_text()
        self.assertIn('bind-address = $DB_IP', script)
        self.assertNotIn('bind-address = 0.0.0.0', script)

    def test_prod_deploy(self):
        self.run_script('deploy.sh','--http-only')
        s=self.read()
        self.assertEqual({i['name'] for i in s['instances'].values()},{'app','db','proxy'})
        self.assertEqual(set(s['volumes']),{PROJECT+'/vol-db',PROJECT+'/vol-uploads'})
        self.assertEqual(s['instances'][PROJECT+'/app']['devices']['eth0']['ipv4.address'],'10.10.10.11')
        self.assertEqual(s['instances'][PROJECT+'/proxy']['devices']['porta-http']['listen'],'tcp:0.0.0.0:8081')
        self.assertNotIn('porta-https',s['instances'][PROJECT+'/proxy']['devices'])
        self.assertFalse(any(x['args'][0]=='delete' for x in s['log']))
    def test_dev_and_prod_isolated(self):
        self.seed(); s=self.read()
        self.assertEqual(len(s['instances']),6)
        dev=s['instances'][PROJECT+'/dev-app']
        self.assertEqual(dev['devices']['eth0']['network'],'net-dev')
        self.assertEqual(dev['devices']['eth0']['ipv4.address'],'10.10.20.11')
        self.assertEqual(dev['devices']['uploads']['source'],'dev-vol-uploads')
        self.assertEqual(s['instances'][PROJECT+'/dev-proxy']['devices']['porta-http']['listen'],'tcp:0.0.0.0:8082')
        self.assertNotIn('porta-https',s['instances'][PROJECT+'/dev-proxy']['devices'])
        maria=[x['args'] for x in s['log'] if '/root/config-mariadb.sh' in x['args'] and x['args'][0]=='exec'][-1]
        self.assertIn('10.10.20.12',maria); self.assertIn('10.10.20.11',maria)
        wp=[x['args'] for x in s['log'] if '/root/instala-wp.sh' in x['args'] and x['args'][0]=='exec'][-1]
        self.assertIn('10.10.20.12',wp); self.assertIn('http://127.0.0.1:8082',wp)
    def test_deploy_existing_refuses_deletion(self):
        self.run_script('deploy.sh','--http-only'); before=self.read()
        self.run_script('deploy.sh','--http-only',success=False)
        self.assertEqual(before['instances'],self.read()['instances'])
        self.assertFalse(any(x['args'][0]=='delete' for x in self.read()['log']))
    def test_destroy_keeps_volumes_and_other_environment(self):
        self.seed(); before=self.read()
        self.run_script('destroy.sh','--yes')
        after=self.read()
        self.assertEqual({i['name'] for i in after['instances'].values()},{'dev-app','dev-db','dev-proxy'})
        self.assertEqual(set(before['volumes']),set(after['volumes']))
        self.assertEqual(before['networks'],after['networks']); self.assertEqual(before['profiles'],after['profiles'])
    def test_destroy_volumes_exact_allowlist(self):
        self.seed(); s=self.read()
        s['volumes'][PROJECT+'/vol-outro']={'name':'vol-outro','project':PROJECT,'pool':'pool-final','type':'custom','used_by':[]}; self.write(s)
        self.run_script('destroy.sh','--volumes','--yes','--confirm-volumes',PROJECT+'/prod')
        s=self.read()
        self.assertEqual(set(s['volumes']),{PROJECT+'/dev-vol-db',PROJECT+'/dev-vol-uploads',PROJECT+'/vol-outro'})
    def test_dev_destroy_keeps_prod(self):
        self.seed(); self.run_script('destroy.sh','--yes','--volumes','--confirm-volumes',PROJECT+'/dev',env={'ENV':'dev'})
        self.assertEqual(set(self.read()['volumes']),{PROJECT+'/vol-db',PROJECT+'/vol-uploads'})
        self.assertEqual({i['name'] for i in self.read()['instances'].values()},{'app','db','proxy'})
    def test_destroy_volumes_without_token_aborts_before_any_delete(self):
        self.seed(); before=self.read()
        self.run_script('destroy.sh','--volumes','--yes',success=False)
        after=self.read()
        self.assertEqual(before['instances'],after['instances'])
        self.assertEqual(before['volumes'],after['volumes'])
        self.assertFalse(any(x['args'] and (x['args'][0]=='delete' or x['args'][:3]==['storage','volume','delete']) for x in after['log']))

    def test_destroy_volumes_with_wrong_token_aborts_before_any_delete(self):
        self.seed(); before=self.read()
        self.run_script('destroy.sh','--volumes','--yes','--confirm-volumes',PROJECT+'/dev',success=False)
        after=self.read()
        self.assertEqual(before['instances'],after['instances'])
        self.assertEqual(before['volumes'],after['volumes'])
        self.assertFalse(any(x['args'] and (x['args'][0]=='delete' or x['args'][:3]==['storage','volume','delete']) for x in after['log']))

    def test_confirmation_required(self):
        self.run_script('deploy.sh','--http-only'); before=self.read()['instances']
        self.run_script('destroy.sh',success=False)
        self.assertEqual(before,self.read()['instances'])
    def test_dry_run_no_lxc_calls(self):
        self.run_script('deploy.sh','--dry-run'); self.run_script('destroy.sh','--dry-run','--volumes')
        self.assertEqual(self.read()['log'],[])
    def test_invalid_env_fails_without_calls(self):
        for script in ('deploy.sh','destroy.sh'):
            self.run_script(script,'--dry-run',env={'ENV':'prodd'},success=False)
        self.assertEqual(self.read()['log'],[])
    def test_remote_guard(self):
        s=self.read(); s['remote']='servidor-remoto'; self.write(s)
        self.run_script('deploy.sh','--http-only',success=False)
        self.assertEqual(self.read()['instances'],{})
    def test_evidence_collector_rejects_mock_state_without_writing_evidence(self):
        output=self.base/'evidence'
        result=self.run_script('registrar-evidencias.sh','--out',str(output),success=False)
        self.assertIn('MOCK_STATE',result.stderr)
        self.assertFalse(output.exists())
        self.assertEqual(self.read()['log'],[])
    def test_delete_failure_prevents_volume_deletion(self):
        self.seed(); s=self.read(); s['fail_on']=['delete']; self.write(s)
        self.run_script('destroy.sh','--yes','--volumes','--confirm-volumes',PROJECT+'/prod',success=False)
        self.assertEqual(len(self.read()['volumes']),4)
        self.assertFalse(any(x['args'][:3]==['storage','volume','delete'] for x in self.read()['log']))
    def test_foreign_volume_attachment_aborts_before_delete(self):
        self.seed(); s=self.read(); s['volumes'][PROJECT+'/vol-db']['used_by'].append('/1.0/instances/dev-db?project='+PROJECT); self.write(s)
        self.run_script('destroy.sh','--yes','--volumes','--confirm-volumes',PROJECT+'/prod',success=False)
        self.assertEqual(len(self.read()['instances']),6)
    def test_shared_profile_changes_abort_before_recreate(self):
        self.seed(); s=self.read(); s['profiles']['perfil-base']['config']['limits.cpu']='2'; s['profiles']['perfil-base']['used_by']=['/1.0/instances/dev-app?project='+PROJECT]; self.write(s)
        self.run_script('deploy.sh','--http-only','--recreate','--yes',success=False)
        self.assertEqual(len(self.read()['instances']),6)
    def test_recreate_preserves_volume_names(self):
        self.seed(); before=set(self.read()['volumes'])
        self.run_script('deploy.sh','--http-only','--recreate','--yes')
        self.assertEqual(before,set(self.read()['volumes']))
        self.assertEqual(len(self.read()['instances']),6)
    def test_repeat_destroy_is_safe(self):
        self.run_script('deploy.sh','--http-only'); self.run_script('destroy.sh','--yes'); self.run_script('destroy.sh','--yes')
        self.assertEqual(len(self.read()['volumes']),2)
    def test_project_query_failure_not_treated_as_absent(self):
        s=self.read(); s['fail_on']=['project','list']; self.write(s)
        self.run_script('deploy.sh','--http-only',success=False)
        self.assertEqual(self.read()['projects'],{})
    def test_incompatible_volume_scope_refused(self):
        s=self.read(); s['projects'][PROJECT]={**FEATURES,'features.storage.volumes':'false'}; self.write(s)
        self.run_script('deploy.sh','--http-only',success=False)
        self.run_script('destroy.sh','--yes','--volumes','--confirm-volumes',PROJECT+'/prod',success=False)
        self.assertEqual(self.read()['instances'],{})

    def test_monitor_filters_environment(self):
        self.seed()
        out=self.run_script('monitor.sh','--once',env={'ENV':'dev'}).stdout
        self.assertIn('dev-app',out)
        self.assertIn('lxd_cpu_seconds_total',out)
        self.assertNotIn('name="app"',out)
        self.assertIn('Guest df',out)
    def test_monitor_metrics_failure_is_nonfatal(self):
        self.run_script('deploy.sh','--http-only'); s=self.read(); s['fail_on']=['query']; self.write(s)
        out=self.run_script('monitor.sh','--once').stdout
        self.assertIn('indisponível',out)
    def test_limits_match_mock_configuration(self):
        self.run_script('deploy.sh','--http-only')
        self.run_script('test-limits.sh')
    def test_limits_reject_memory_mismatch(self):
        self.run_script('deploy.sh','--http-only'); s=self.read(); s['probe_memory']=2147483648; self.write(s)
        self.run_script('test-limits.sh',success=False)
    def test_load_only_dev_app_with_guest_timeout(self):
        self.seed(); self.run_script('test-limits.sh','--load',env={'ENV':'dev'})
        loads=[x['args'] for x in self.read()['log'] if x['args'][0]=='exec' and 'timeout' in x['args']]
        self.assertEqual(len(loads),1)
        self.assertEqual(loads[0][1],'dev-app')
        self.assertIn('20s',loads[0])
        self.assertIn('yes > /dev/null',loads[0])
    def test_load_refused_in_prod(self):
        self.run_script('deploy.sh','--http-only'); self.run_script('test-limits.sh','--load',success=False)
        self.assertFalse(any(x['args'][0]=='exec' and 'timeout' in x['args'] for x in self.read()['log']))

if __name__ == '__main__': unittest.main(verbosity=2)
