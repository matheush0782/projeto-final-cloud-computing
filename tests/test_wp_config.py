#!/usr/bin/env python3
"""Testes PHP e de cópia do core com fixtures, sem serviços nem diretórios reais."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT/'conf/instala-wp.sh').read_text()
PHP = SCRIPT.split("<<'PHP'\n",1)[1].split('\nPHP\n',1)[0]

@unittest.skipUnless(shutil.which('php'), 'PHP CLI necessário para estes testes')
class ConfigTest(unittest.TestCase):
    def test_config_generation_special_characters_and_idempotence(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp); source=base/'source.php'
            fixture="<?php\ndefine( 'DB_NAME', 'database_name_here' );\ndefine( 'DB_USER', 'username_here' );\ndefine( 'DB_PASSWORD', 'password_here' );\ndefine( 'DB_HOST', 'localhost' );\ndefine( 'AUTH_KEY', 'put your unique phrase here' );\n/* That's all, stop editing! */\n"
            source.write_text(fixture)
            env={**os.environ,'WP_DB_NAME':'wordpress','WP_DB_USER':'wpuser','WP_DB_PASS':"teste'$1\\barra",'WP_DB_HOST':'10.10.20.12','WP_SITE_URL':'http://127.0.0.1:8082'}
            generated=subprocess.run(['php','/dev/stdin',str(source)],input=PHP,text=True,capture_output=True,env=env,check=True).stdout
            target=base/'config.php'; target.write_text(generated)
            subprocess.run(['php','-l',str(target)],capture_output=True,check=True)
            self.assertIn('10.10.20.12',generated); self.assertIn('http://127.0.0.1:8082',generated)
            self.assertNotIn('put your unique phrase here',generated)
            rerun=subprocess.run(['php','/dev/stdin',str(target)],input=PHP,text=True,capture_output=True,env=env,check=True).stdout
            self.assertEqual(generated,rerun)
            eval_script=base/'check.php'; eval_script.write_text("<?php require $argv[1]; echo DB_PASSWORD; ")
            password=subprocess.run(['php',str(eval_script),str(target)],capture_output=True,text=True,check=True).stdout
            self.assertEqual(password,env['WP_DB_PASS'])
    def test_core_copy_keeps_uploads_and_existing_theme(self):
        start=SCRIPT.index('    instalar_core() {')
        end=SCRIPT.index('\n    instalar_core\n',start)
        block=SCRIPT[start:end]
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp); core=base/'core'; root=base/'docroot'
            for p in ('wp-admin','wp-includes','wp-content/themes/default','wp-content/plugins'):
                (core/p).mkdir(parents=True,exist_ok=True)
            (core/'wp-config-sample.php').write_text('<?php // sample\n')
            (core/'index.php').write_text('<?php // index\n')
            (core/'wp-content/themes/default/style.css').write_text('theme-default')
            (root/'wp-content/uploads').mkdir(parents=True)
            (root/'wp-content/uploads/foto.txt').write_text('UPLOAD PERSISTENTE')
            subprocess.run(['bash','-c',block+'\ninstalar_core\n'],env={**os.environ,'CORE_DIR':str(core),'DOCROOT':str(root)},check=True)
            self.assertEqual((root/'wp-content/uploads/foto.txt').read_text(),'UPLOAD PERSISTENTE')
            self.assertTrue((root/'wp-content/themes/default/style.css').exists())
            self.assertTrue((root/'wp-config-sample.php').exists())
            (root/'wp-content/themes/default/style.css').write_text('CUSTOMIZADO')
            subprocess.run(['bash','-c',block+'\ninstalar_core\n'],env={**os.environ,'CORE_DIR':str(core),'DOCROOT':str(root)},check=True)
            self.assertEqual((root/'wp-content/themes/default/style.css').read_text(),'CUSTOMIZADO')
            self.assertEqual((root/'wp-content/uploads/foto.txt').read_text(),'UPLOAD PERSISTENTE')

if __name__=='__main__': unittest.main(verbosity=2)
