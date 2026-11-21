#!/usr/bin/env python3
"""Teste puro do filtro de dados; não cria evidência e não consulta LXD."""
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT/'scripts/registrar-evidencias.sh').read_text()
FILTER = SOURCE.split('filtrar_json_publico() {',1)[1].split('\n}\nlistar_publico()',1)[0]

class PublicEvidenceTest(unittest.TestCase):
    def test_excludes_sensitive_fields_in_all_json_outputs(self):
        fixture = [{'name':'app','status':'Running','type':'container','managed':True,
                    'config':{'DB_PASSWORD':'SEGREDO_NAO_PUBLICAR','cloud-init.user-data':'SEGREDO_NAO_PUBLICAR','ipv4.address':'10.10.10.1/24'},
                    'expanded_config':{'user.password':'SEGREDO_NAO_PUBLICAR'},
                    'devices':{'private':'SEGREDO_NAO_PUBLICAR'},
                    'used_by':['/1.0/instances/app?project=final-equipeN']}]
        for kind in ('instances','networks','volumes'):
            with self.subTest(kind=kind):
                command='filtrar_json_publico() {'+FILTER+'\n}\nfiltrar_json_publico '+kind
                result=subprocess.run(['bash','-c',command],input=json.dumps(fixture),text=True,capture_output=True,check=True)
                self.assertNotIn('SEGREDO_NAO_PUBLICAR',result.stdout)
                self.assertNotIn('expanded_config',result.stdout)
                self.assertEqual(json.loads(result.stdout)[0]['name'],'app')

if __name__=='__main__': unittest.main(verbosity=2)
