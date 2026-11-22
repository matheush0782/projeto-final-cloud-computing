#!/usr/bin/env python3
"""Testes de conformidade e integridade dos artefatos da Fase 4."""
import json
from pathlib import Path
import unittest

try:
    import yaml
except ImportError:
    yaml = None

ROOT = Path(__file__).resolve().parents[1]
CONF = ROOT / "conf"
SCRIPTS = ROOT / "scripts"
DOCS = ROOT / "docs"
EVIDENCIAS_FASE4 = DOCS / "evidencias" / "fase4"


class Fase4Test(unittest.TestCase):
    def test_acl_prod_yaml_structure(self):
        acl_prod_path = CONF / "acl-prod.yaml"
        self.assertTrue(acl_prod_path.is_file(), "conf/acl-prod.yaml deve existir")
        content = acl_prod_path.read_text(encoding="utf-8")
        if yaml is not None:
            data = yaml.safe_load(content)
            self.assertEqual(data.get("name"), "acl-prod")
            rules = data.get("rules", [])
            self.assertGreaterEqual(len(rules), 2)
            has_ingress_drop = any(
                r.get("direction") == "ingress"
                and r.get("action") == "drop"
                and r.get("source") == "10.10.20.0/24"
                for r in rules
            )
            has_egress_drop = any(
                r.get("direction") == "egress"
                and r.get("action") == "drop"
                and r.get("destination") == "10.10.20.0/24"
                for r in rules
            )
            self.assertTrue(has_ingress_drop, "acl-prod deve descartar ingress de 10.10.20.0/24")
            self.assertTrue(has_egress_drop, "acl-prod deve descartar egress para 10.10.20.0/24")

    def test_acl_dev_yaml_structure(self):
        acl_dev_path = CONF / "acl-dev.yaml"
        self.assertTrue(acl_dev_path.is_file(), "conf/acl-dev.yaml deve existir")
        content = acl_dev_path.read_text(encoding="utf-8")
        if yaml is not None:
            data = yaml.safe_load(content)
            self.assertEqual(data.get("name"), "acl-dev")
            rules = data.get("rules", [])
            self.assertGreaterEqual(len(rules), 2)
            has_ingress_drop = any(
                r.get("direction") == "ingress"
                and r.get("action") == "drop"
                and r.get("source") == "10.10.10.0/24"
                for r in rules
            )
            has_egress_drop = any(
                r.get("direction") == "egress"
                and r.get("action") == "drop"
                and r.get("destination") == "10.10.10.0/24"
                for r in rules
            )
            self.assertTrue(has_ingress_drop, "acl-dev deve descartar ingress de 10.10.10.0/24")
            self.assertTrue(has_egress_drop, "acl-dev deve descartar egress para 10.10.10.0/24")

    def test_fase4_script_structure(self):
        script_path = SCRIPTS / "fase4-acls.sh"
        self.assertTrue(script_path.is_file(), "scripts/fase4-acls.sh deve existir")
        content = script_path.read_text(encoding="utf-8")
        self.assertIn("#!/usr/bin/env bash", content)
        self.assertIn("common.sh", content)
        self.assertIn("--status", content)
        self.assertIn("--dry-run", content)
        self.assertIn("--apply", content)
        self.assertIn("--test", content)
        self.assertIn("--rollback", content)
        self.assertIn("acl-prod", content)
        self.assertIn("acl-dev", content)
        self.assertIn("security.acls.default.ingress.action", content)
        self.assertIn("security.acls.default.egress.action", content)

    def test_evidencias_fase4_presentes(self):
        arquivos_esperados = [
            "01-estado-inicial.txt",
            "02-teste-antes-acl.txt",
            "03-acls-aplicadas.txt",
            "04-teste-depois-acl.txt",
            "05-validacao-servico.txt",
        ]
        self.assertTrue(EVIDENCIAS_FASE4.is_dir(), "docs/evidencias/fase4 deve ser um diretório")
        for nome in arquivos_esperados:
            arquivo = EVIDENCIAS_FASE4 / nome
            self.assertTrue(arquivo.is_file(), f"{nome} deve existir em docs/evidencias/fase4/")
            conteudo = arquivo.read_text(encoding="utf-8")
            self.assertGreater(len(conteudo.strip()), 100, f"{nome} não deve estar vazio")

        # Conteúdo específico de cada evidência
        e01 = (EVIDENCIAS_FASE4 / "01-estado-inicial.txt").read_text(encoding="utf-8")
        self.assertIn("net-prod", e01)
        self.assertIn("net-dev", e01)
        self.assertIn("proxy", e01)

        e02 = (EVIDENCIAS_FASE4 / "02-teste-antes-acl.txt").read_text(encoding="utf-8")
        self.assertIn("ALCANCOU", e02)
        self.assertIn("teste-dev", e02)

        e03 = (EVIDENCIAS_FASE4 / "03-acls-aplicadas.txt").read_text(encoding="utf-8")
        self.assertIn("lxc network acl show acl-prod", e03)
        self.assertIn("security.acls: acl-prod", e03)

        e04 = (EVIDENCIAS_FASE4 / "04-teste-depois-acl.txt").read_text(encoding="utf-8")
        self.assertIn("BLOQUEADO", e04)
        self.assertIn("deb.debian.org", e04)

        e05 = (EVIDENCIAS_FASE4 / "05-validacao-servico.txt").read_text(encoding="utf-8")
        self.assertIn("Test-NetConnection", e05)
        self.assertIn("8081", e05)
        self.assertIn("3306", e05)

    def test_documentacao_fase4(self):
        doc = DOCS / "fase4-isolamento.md"
        self.assertTrue(doc.is_file(), "docs/fase4-isolamento.md deve existir")
        conteudo = doc.read_text(encoding="utf-8")
        self.assertIn("Fase 4", conteudo)
        self.assertIn("ALCANCOU", conteudo)
        self.assertIn("BLOQUEADO", conteudo)
        self.assertIn("acl-prod", conteudo)
        self.assertIn("acl-dev", conteudo)
        self.assertIn("default", conteudo)


if __name__ == "__main__":
    unittest.main(verbosity=2)
