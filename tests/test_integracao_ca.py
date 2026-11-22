#!/usr/bin/env python3
"""Integração local da Fase 5: OpenSSL real, LXC e curl somente simulados."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROJECT = "final-equipeN"


class CAIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.repo = self.base / "repo"
        shutil.copytree(
            ROOT,
            self.repo,
            ignore=shutil.ignore_patterns(".git", "__pycache__", "tls"),
        )
        self.state = self.base / "state.json"
        self.state.write_text(
            json.dumps(
                {
                    "projects": {},
                    "instances": {},
                    "profiles": {},
                    "networks": {},
                    "pools": {},
                    "volumes": {},
                    "log": [],
                }
            )
        )
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        shutil.copy(ROOT / "tests/mock_lxc.py", bin_dir / "lxc")
        (bin_dir / "lxc").chmod(0o755)
        self.curl_log = self.base / "curl.log"
        fake_curl = bin_dir / "curl"
        fake_curl.write_text(
            "#!/bin/sh\n"
            'printf "%s\\n" "$@" >> "${FAKE_CURL_LOG:?}"\n'
            "exit 0\n"
        )
        fake_curl.chmod(0o755)
        self.env = dict(
            os.environ,
            PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
            MOCK_STATE=str(self.state),
            FAKE_CURL_LOG=str(self.curl_log),
            PROJETO=PROJECT,
            POOL="pool-final",
            ENV="prod",
            DB_PASS="SenhaMock123",
            VM_HOST="127.0.0.1",
            IP_VM="10.0.2.15",
        )

    def tearDown(self):
        self.tmp.cleanup()

    def read_state(self):
        return json.loads(self.state.read_text())

    def write_state(self, value):
        self.state.write_text(json.dumps(value))

    def run_script(self, script, *args, env=None, success=True, timeout=180):
        result = subprocess.run(
            ["bash", str(self.repo / "scripts" / script), *args],
            env={**self.env, **(env or {})},
            cwd=self.repo,
            capture_output=True,
            text=True,
            timeout=timeout,
            stdin=subprocess.DEVNULL,
        )
        message = result.stdout + "\n" + result.stderr
        if success:
            self.assertEqual(result.returncode, 0, message)
        else:
            self.assertNotEqual(result.returncode, 0, message)
        return result

    def seed_phase5(self, environment):
        state = self.read_state()
        prefix = "" if environment == "prod" else "dev-"
        http_port = "8081" if environment == "prod" else "8082"
        for role in ("proxy", "app"):
            name = prefix + role
            state["instances"][f"{PROJECT}/{name}"] = {
                "name": name,
                "project": PROJECT,
                "status": "Running",
                "expanded_config": {},
                "devices": {},
            }
        proxy = state["instances"][f"{PROJECT}/{prefix}proxy"]
        proxy["devices"]["porta-http"] = {
            "type": "proxy",
            "listen": f"tcp:0.0.0.0:{http_port}",
            "connect": "tcp:127.0.0.1:80",
        }
        self.write_state(state)

    def run_tls(self, environment, **extra_env):
        env = {
            "ENV": environment,
            "IP_VM": "10.0.2.15",
            "IP_SITE": "127.0.0.1",
            **extra_env,
        }
        return self.run_script("fase5-tls.sh", env=env)

    @staticmethod
    def openssl(*args):
        return subprocess.run(
            ["openssl", *args], capture_output=True, text=True, check=True
        ).stdout

    @staticmethod
    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def tls_paths(self, environment):
        directory = self.repo / "conf" / "tls" / environment
        return directory, directory / "ca.crt", directory / "servico.crt"

    def test_prod_tls_real_chain_reused_without_duplicate_proxy(self):
        self.seed_phase5("prod")
        self.run_tls("prod")
        tls_dir, ca_crt, service_crt = self.tls_paths("prod")
        self.assertTrue(tls_dir.is_dir())
        self.assertEqual(
            self.openssl("verify", "-CAfile", str(ca_crt), str(service_crt)).strip(),
            f"{service_crt}: OK",
        )
        subject = self.openssl("x509", "-in", str(service_crt), "-noout", "-subject")
        issuer = self.openssl("x509", "-in", str(service_crt), "-noout", "-issuer")
        self.assertNotEqual(subject.split("=", 1)[1].strip(), issuer.split("=", 1)[1].strip(), "o certificado de serviço não pode ser autoassinado")
        san = self.openssl(
            "x509", "-in", str(service_crt), "-noout", "-ext", "subjectAltName"
        )
        for address in ("10.0.2.15", "127.0.0.1"):
            self.assertIn(f"IP Address:{address}", san)
        ca_key = self.openssl("pkey", "-in", str(tls_dir / "ca.key"), "-text", "-noout")
        self.assertIn("4096 bit", ca_key)
        public_from_key = self.openssl("pkey", "-in", str(tls_dir / "servico.key"), "-pubout")
        public_from_cert = self.openssl("x509", "-in", str(service_crt), "-pubkey", "-noout")
        self.assertEqual(public_from_key, public_from_cert)
        first_ca_hash = self.digest(ca_crt)
        first_service_hash = self.digest(service_crt)

        state = self.read_state()
        proxy = state["instances"][f"{PROJECT}/proxy"]
        https = proxy["devices"]["porta-https"]
        self.assertEqual(https["type"], "proxy")
        self.assertEqual(https["listen"], "tcp:0.0.0.0:8444")
        self.assertEqual(https["connect"], "tcp:127.0.0.1:443")
        self.assertEqual(sum("porta-https" in i["devices"] for i in state["instances"].values()), 1)
        self.assertFalse(any("8443" in arg for entry in state["log"] for arg in entry["args"]))
        self.assertTrue(
            any(
                entry["args"][:2] == ["file", "push"]
                and "--mode" in entry["args"]
                and "0600" in entry["args"]
                for entry in state["log"]
            )
        )
        updater = [
            entry["args"]
            for entry in state["log"]
            if entry["args"][:1] == ["exec"]
            and "/root/atualiza-url-wp.php" in entry["args"]
        ]
        self.assertTrue(updater)
        self.assertTrue(any("WP_SITE_URL=https://127.0.0.1:8444" in args for args in updater))

        self.run_tls("prod")
        state = self.read_state()
        self.assertEqual(first_ca_hash, self.digest(ca_crt))
        self.assertEqual(first_service_hash, self.digest(service_crt))
        self.assertEqual(
            sum(
                entry["args"][:5] == ["config", "device", "add", "proxy", "porta-https"]
                for entry in state["log"]
            ),
            1,
        )
        self.assertEqual(state["instances"][f"{PROJECT}/proxy"]["devices"]["porta-https"]["type"], "proxy")

        curl_args = self.curl_log.read_text().splitlines()
        self.assertIn("--cacert", curl_args)
        self.assertNotIn("--insecure", curl_args)
        self.assertNotIn("-k", curl_args)

    def test_https_template_uses_fixed_site_host_not_client_host_header(self):
        template = (ROOT / "conf" / "nginx-servico-https.conf").read_text()
        self.assertIn("https://__SITE_HOST__$request_uri", template)
        self.assertIn("proxy_set_header Host __SITE_HOST__;", template)
        self.assertIn("proxy_set_header X-Forwarded-Host __SITE_HOST__;", template)
        self.assertNotIn("https://$host:", template)
        self.assertNotIn("proxy_set_header Host $http_host;", template)

    def test_dev_tls_uses_8445_and_wordpress_https_url(self):
        self.seed_phase5("dev")
        self.run_tls("dev", IP_SITE="127.0.0.1")
        state = self.read_state()
        proxy = state["instances"][f"{PROJECT}/dev-proxy"]
        self.assertEqual(proxy["devices"]["porta-http"]["listen"], "tcp:0.0.0.0:8082")
        self.assertEqual(proxy["devices"]["porta-https"]["listen"], "tcp:0.0.0.0:8445")
        self.assertEqual(proxy["devices"]["porta-https"]["type"], "proxy")
        self.assertFalse(any("8443" in arg for entry in state["log"] for arg in entry["args"]))
        updater = [
            entry["args"]
            for entry in state["log"]
            if entry["args"][:1] == ["exec"]
            and "/root/atualiza-url-wp.php" in entry["args"]
        ]
        self.assertTrue(any("WP_SITE_URL=https://127.0.0.1:8445" in args for args in updater))
        curl_args = self.curl_log.read_text().splitlines()
        self.assertIn("--cacert", curl_args)
        self.assertNotIn("--insecure", curl_args)

    def test_default_deploy_applies_ca_and_recreation_reuses_public_certificates(self):
        self.run_script("deploy.sh", env={"IP_VM": "10.0.2.15"}, timeout=240)
        _, ca_crt, service_crt = self.tls_paths("prod")
        first_ca_hash = self.digest(ca_crt)
        first_service_hash = self.digest(service_crt)
        self.assertEqual(
            self.openssl("verify", "-CAfile", str(ca_crt), str(service_crt)).strip(),
            f"{service_crt}: OK",
        )
        state = self.read_state()
        proxy = state["instances"][f"{PROJECT}/proxy"]
        self.assertEqual(proxy["devices"]["porta-http"]["listen"], "tcp:0.0.0.0:8081")
        self.assertEqual(proxy["devices"]["porta-https"]["listen"], "tcp:0.0.0.0:8444")
        self.assertEqual(proxy["devices"]["porta-https"]["type"], "proxy")
        self.assertFalse(any("8443" in arg for entry in state["log"] for arg in entry["args"]))
        updater = [
            entry["args"]
            for entry in state["log"]
            if entry["args"][:1] == ["exec"]
            and "/root/atualiza-url-wp.php" in entry["args"]
        ]
        self.assertTrue(any("WP_SITE_URL=https://127.0.0.1:8444" in args for args in updater))

        self.run_script(
            "deploy.sh",
            "--recreate",
            "--yes",
            env={"IP_VM": "10.0.2.15"},
            timeout=240,
        )
        state = self.read_state()
        self.assertEqual(first_ca_hash, self.digest(ca_crt))
        self.assertEqual(first_service_hash, self.digest(service_crt))
        recreated_proxy = state["instances"][f"{PROJECT}/proxy"]
        self.assertEqual(
            sum("porta-https" in instance["devices"] for instance in state["instances"].values()),
            1,
        )
        self.assertEqual(recreated_proxy["devices"]["porta-https"]["type"], "proxy")
        self.assertEqual(recreated_proxy["devices"]["porta-https"]["listen"], "tcp:0.0.0.0:8444")
        self.assertFalse(any("8443" in arg for entry in state["log"] for arg in entry["args"]))

    def test_default_deploy_rejects_invalid_ip_before_any_lxc_call(self):
        self.run_script(
            "deploy.sh",
            env={"ENV": "prod", "IP_VM": "999.1.1.1"},
            success=False,
        )
        self.assertEqual(self.read_state()["log"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
