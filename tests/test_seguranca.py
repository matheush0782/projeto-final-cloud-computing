#!/usr/bin/env python3
"""Testes direcionados para os contratos de segurança da PR, sem serviços reais."""
import hashlib
import json
import os
from pathlib import Path
import pwd
import shutil
import signal
import stat
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
DEPLOY = ROOT / "scripts" / "deploy.sh"
MARIADB = ROOT / "conf" / "config-mariadb.sh"
WORDPRESS = ROOT / "conf" / "instala-wp.sh"
UPDATER = ROOT / "conf" / "atualiza-url-wp.php"
MOCK = ROOT / "tests" / "mock_lxc.py"
SECRET_ENV_NAMES = (
    "DB_PASS",
    "DB_PASS_PROD",
    "DB_PASS_DEV",
    "SENHA_BANCO",
    "WP_DB_PASS",
    "MYSQL_PWD",
)
try:
    WWW_DATA = pwd.getpwnam("www-data")
except KeyError:
    WWW_DATA = None
SUDO_READY = bool(shutil.which("sudo")) and subprocess.run(
    ["sudo", "-n", "true"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
).returncode == 0
FILESYSTEM_READY = SUDO_READY and WWW_DATA is not None and shutil.which("php") is not None


def sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sudo_command(argv, env=None):
    command = ["sudo", "-n"]
    if env:
        command += ["env"] + [f"{key}={value}" for key, value in env.items()]
    command += list(argv)
    return command


def sudo_run(argv, *, input=None, env=None, timeout=30):
    return subprocess.run(
        sudo_command(argv, env=env),
        input=input,
        text=True,
        capture_output=True,
        timeout=timeout,
    )


class MockDeployMixin:
    """Harnessa somente lxc; nenhum daemon, VM ou caminho do host é usado."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="test-seguranca-")
        self.base = Path(self.tmp.name)
        self.state_path = self.base / "state.json"
        self.state_path.write_text(
            json.dumps(
                {
                    "projects": {},
                    "instances": {},
                    "profiles": {},
                    "networks": {},
                    "pools": {},
                    "volumes": {},
                    "log": [],
                    "secret_inputs": [],
                }
            )
        )
        bindir = self.base / "bin"
        bindir.mkdir()
        fake_lxc = bindir / "lxc"
        shutil.copy2(MOCK, fake_lxc)
        fake_lxc.chmod(0o755)
        self.env = dict(os.environ)
        for name in SECRET_ENV_NAMES:
            self.env.pop(name, None)
        self.env.update(
            {
                "PATH": str(bindir) + os.pathsep + self.env.get("PATH", ""),
                "MOCK_STATE": str(self.state_path),
                "PROJETO": "seguranca-test",
                "POOL": "pool-test",
                "VM_HOST": "127.0.0.1",
            }
        )

    def tearDown(self):
        self.tmp.cleanup()

    def reset_state(self, **values):
        state = {
            "projects": {},
            "instances": {},
            "profiles": {},
            "networks": {},
            "pools": {},
            "volumes": {},
            "log": [],
            "secret_inputs": [],
        }
        state.update(values)
        self.state_path.write_text(json.dumps(state))

    def state(self):
        return json.loads(self.state_path.read_text())

    def run_deploy(self, *args, trace=False, env=None, success=True):
        command = ["bash"]
        if trace:
            command.append("-x")
        command += [str(DEPLOY), *args]
        child_env = dict(self.env)
        for name, value in (env or {}).items():
            if value is None:
                child_env.pop(name, None)
            else:
                child_env[name] = value
        result = subprocess.run(
            command,
            env=child_env,
            input="",
            text=True,
            capture_output=True,
            timeout=90,
        )
        if success:
            self.assertEqual(
                result.returncode,
                0,
                msg=f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )
        else:
            self.assertNotEqual(
                result.returncode,
                0,
                msg="o cenário deveria falhar, mas terminou com sucesso",
            )
        return result

    def assert_no_secret_value(self, marker, result=None):
        serialized = json.dumps(self.state(), ensure_ascii=False)
        if result is not None:
            serialized += result.stdout + result.stderr
        self.assertNotIn(marker, serialized)

    def assert_secret_trace(self, marker, result=None):
        state = self.state()
        expected = (marker + "\n").encode()
        entries = state["secret_inputs"]
        self.assertEqual([entry["kind"] for entry in entries], ["mariadb", "wordpress", "health"])
        for entry in entries:
            self.assertEqual(entry["length"], len(expected))
            self.assertEqual(entry["sha256"], sha256(expected))
            self.assertEqual(set(entry["env_credentials"]), set(SECRET_ENV_NAMES))
            self.assertFalse(any(entry["env_credentials"].values()))
        for log in state["log"]:
            self.assertEqual(set(log["env_credentials"]), set(SECRET_ENV_NAMES))
            self.assertFalse(any(log["env_credentials"].values()))
            args = log["args"]
            if args[:1] == ["exec"] and "--" in args:
                separator = args.index("--")
                command = args[separator + 1 :]
                script_lengths = {
                    ("bash", "/root/config-mariadb.sh"): 7,
                    ("bash", "/root/instala-wp.sh"): 7,
                }
                expected_length = script_lengths.get(tuple(command[:2]))
                if expected_length is not None or command[:2] == ["php", "-r"]:
                    self.assertIn("--mode=non-interactive", args[:separator])
                    self.assertNotIn("<redacted>", command)
                    if expected_length is not None:
                        self.assertEqual(len(command), expected_length)
                        self.assertEqual(command[2], "--password-stdin")
                    else:
                        self.assertEqual(len(command), 6)
        self.assert_no_secret_value(marker, result)


class DeployCredentialTests(MockDeployMixin, unittest.TestCase):
    def test_prod_and_dev_send_exact_secret_stdin_to_all_three_destinations(self):
        for environment, variable, marker in (
            ("prod", "DB_PASS_PROD", "PROD_fake_marker_9"),
            ("dev", "DB_PASS_DEV", "DEV_fake_marker_8"),
        ):
            with self.subTest(environment=environment):
                self.reset_state()
                result = self.run_deploy(
                    "--http-only",
                    env={"ENV": environment, variable: marker},
                )
                self.assert_secret_trace(marker, result)

    def test_db_pass_precedence_preserves_common_override_and_environment_fallbacks(self):
        cases = (
            ("prod", {"DB_PASS": "COMMON_prod_1", "DB_PASS_PROD": "PROD_fallback_2"}, "COMMON_prod_1"),
            ("dev", {"DB_PASS": "COMMON_dev_3", "DB_PASS_DEV": "DEV_fallback_4"}, "COMMON_dev_3"),
            ("prod", {"DB_PASS_PROD": "PROD_fallback_5"}, "PROD_fallback_5"),
            ("dev", {"DB_PASS_DEV": "DEV_fallback_6"}, "DEV_fallback_6"),
        )
        for environment, credentials, expected in cases:
            with self.subTest(environment=environment, credentials=tuple(credentials)):
                self.reset_state()
                result = self.run_deploy(
                    "--http-only",
                    env={"ENV": environment, **credentials},
                )
                self.assert_secret_trace(expected, result)

    def test_missing_password_aborts_before_any_lxc_call(self):
        self.reset_state()
        result = self.run_deploy("--http-only", env={"ENV": "prod"}, success=False)
        state = self.state()
        self.assertEqual(state["log"], [])
        self.assertEqual(state["secret_inputs"], [])
        self.assertIn("Não há senha padrão no código", result.stderr)

    def test_xtrace_never_reveals_deploy_secret(self):
        self.reset_state()
        marker = "XTRACE_fake_marker_7"
        result = self.run_deploy(
            "--http-only",
            trace=True,
            env={"ENV": "prod", "DB_PASS": marker},
        )
        self.assert_secret_trace(marker, result)

    def test_failure_at_wordpress_stops_health_proxy_and_tls(self):
        tls_dir = ROOT / "conf" / "tls"
        if tls_dir.exists():
            self.skipTest("não alterar nem assumir um diretório TLS já existente no checkout")
        marker = "FAIL_fake_marker_6"
        self.reset_state(fail_secret_kind="wordpress")
        result = self.run_deploy(
            env={
                "ENV": "prod",
                "IP_VM": "127.0.0.1",
                "IP_SITE": "127.0.0.1",
                "DB_PASS_PROD": marker,
            },
            success=False,
        )
        state = self.state()
        self.assertEqual([entry["kind"] for entry in state["secret_inputs"]], ["mariadb", "wordpress"])
        self.assertNotIn("health", [entry["kind"] for entry in state["secret_inputs"]])
        self.assertIn("db", {item["name"] for item in state["instances"].values()})
        self.assertIn("app", {item["name"] for item in state["instances"].values()})
        self.assertNotIn("proxy", {item["name"] for item in state["instances"].values()})
        self.assertFalse(any("porta-https" in entry["args"] for entry in state["log"]))
        self.assert_no_secret_value(marker, result)


@unittest.skipUnless(SUDO_READY, "sudo -n sem senha é necessário para testar os scripts como root")
class ScriptInputValidationTests(unittest.TestCase):
    CONFIG_ARGS = ["--password-stdin", "10.10.10.11", "wordpress", "wpuser"]
    WP_ARGS = [
        "--password-stdin",
        "10.10.10.12",
        "http://127.0.0.1:8081",
        "wordpress",
        "wpuser",
    ]

    def run_script(self, script, args, payload, trace=False):
        command = ["bash"]
        if trace:
            command.append("-x")
        command += [str(script), *args]
        return sudo_run(command, input=payload)

    def assert_rejected_without_echo(self, result, *markers):
        self.assertNotEqual(result.returncode, 0)
        output = result.stdout + result.stderr
        for marker in markers:
            self.assertNotIn(marker, output)

    def test_missing_multiline_and_cr_passwords_are_rejected(self):
        cases = (
            (MARIADB, self.CONFIG_ARGS),
            (WORDPRESS, self.WP_ARGS),
        )
        for script, args in cases:
            for payload, markers in (
                ("MULTILINE_fake_1\nSECOND_fake_2\n", ("MULTILINE_fake_1", "SECOND_fake_2")),
                ("CR_fake_3\r\n", ("CR_fake_3",)),
                ("", ()),
            ):
                with self.subTest(script=script.name, payload=repr(payload)):
                    result = self.run_script(script, args, payload)
                    self.assert_rejected_without_echo(result, *markers)

    def test_extra_argv_old_password_form_is_rejected_without_echo(self):
        marker = "ARGV_fake_marker_5"
        result = self.run_script(
            MARIADB,
            [*self.CONFIG_ARGS, marker],
            "unused\n",
        )
        self.assert_rejected_without_echo(result, marker)
        result = self.run_script(
            WORDPRESS,
            [*self.WP_ARGS, marker],
            "unused\n",
        )
        self.assert_rejected_without_echo(result, marker)
        for script, legacy in (
            (MARIADB, ["10.10.10.11", "wordpress", "wpuser", marker]),
            (WORDPRESS, ["10.10.10.12", marker, "http://127.0.0.1:8081", "wordpress", "wpuser"]),
        ):
            self.assert_rejected_without_echo(self.run_script(script, legacy, "unused\n"), marker)

    def test_xtrace_cannot_reveal_rejected_secret_input(self):
        marker = "TRACE_fake_marker_4"
        for script, args in ((MARIADB, self.CONFIG_ARGS), (WORDPRESS, self.WP_ARGS)):
            with self.subTest(script=script.name):
                result = self.run_script(
                    script,
                    args,
                    marker + "\nextra\n",
                    trace=True,
                )
                self.assert_rejected_without_echo(result, marker, "extra")


@unittest.skipUnless(FILESYSTEM_READY, "sudo, PHP e www-data são necessários para o teste de permissões")
class FilesystemSecurityTests(unittest.TestCase):
    def stat_tuple(self, path):
        info = os.stat(path)
        return info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)

    def test_root_wwwdata_0640_readable_but_not_directly_writable_and_updater_idempotent(self):
        with tempfile.TemporaryDirectory(prefix="fase5-permissoes-") as tmp:
            directory = Path(tmp)
            directory.chmod(0o755)
            docroot = directory / "docroot"
            docroot.mkdir()
            target = docroot / "wp-config.php"
            target.write_text(
                "<?php\n"
                "define( 'WP_HOME', 'http://127.0.0.1:8081' );\n"
                "define('WP_SITEURL','http://127.0.0.1:8081');\n"
                "define('DB_PASSWORD', 'nao-e-um-segredo-de-teste');\n"
            )
            production = WORDPRESS.read_text()
            start = production.index('install -d -o www-data -g www-data -m 0755 "$UPLOADS_DIR"')
            end = production.index('\nAPACHE_CONF=', start)
            # Executa as permissões reais da produção, não chown/chmod inventados no teste.
            block = production[start:end]
            try:
                applied = sudo_run(
                    ["bash", "-e", "-c", block],
                    env={
                        "DOCROOT": str(docroot),
                        "UPLOADS_DIR": str(docroot / "wp-content/uploads"),
                        "CONFIG_DESTINO": str(target),
                    },
                )
                self.assertEqual(applied.returncode, 0, applied.stderr)
                self.assertEqual(self.stat_tuple(target), (0, WWW_DATA.pw_gid, 0o640))
                first = sudo_run(
                    ["php", str(UPDATER), str(target)],
                    env={"WP_SITE_URL": "https://127.0.0.1:8444"},
                )
                self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
                first_content_result = sudo_run(["cat", str(target)])
                self.assertEqual(first_content_result.returncode, 0, first_content_result.stderr)
                first_content = first_content_result.stdout
                first_stat = self.stat_tuple(target)
                self.assertEqual(first_stat, (0, WWW_DATA.pw_gid, 0o640))
                readable = sudo_run(["-u", "www-data", "--", "cat", str(target)])
                self.assertEqual(readable.returncode, 0, readable.stderr)
                self.assertEqual(readable.stdout, first_content)
                direct_write = sudo_run([
                    "-u", "www-data", "--", "sh", "-c",
                    'printf DIRECT_WRITE >> "$1"', "sh", str(target),
                ])
                self.assertNotEqual(direct_write.returncode, 0)
                unchanged = sudo_run(["cat", str(target)])
                self.assertEqual(unchanged.returncode, 0, unchanged.stderr)
                self.assertEqual(unchanged.stdout, first_content)
                second = sudo_run(
                    ["php", str(UPDATER), str(target)],
                    env={"WP_SITE_URL": "https://127.0.0.1:8444"},
                )
                self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
                unchanged_again = sudo_run(["cat", str(target)])
                self.assertEqual(unchanged_again.returncode, 0, unchanged_again.stderr)
                self.assertEqual(unchanged_again.stdout, first_content)
                self.assertEqual(self.stat_tuple(target), first_stat)
            finally:
                # O bloco real torna o docroot www-data; remova somente este fixture.
                sudo_run(["rm", "-rf", "--", str(docroot)])


@unittest.skipUnless(SUDO_READY, "sudo -n sem senha é necessário para o harness isolado")
class TemporaryCleanupTests(unittest.TestCase):
    def make_fake_commands(self, directory):
        for name in ("php", "systemctl", "a2enconf", "apache2ctl", "curl", "tar"):
            command = directory / name
            command.write_text("#!/bin/sh\nexit 0\n")
            command.chmod(0o755)

    def make_isolated_wp_script(self, directory, pause=False):
        text = WORDPRESS.read_text()
        old_docroot = "DOCROOT=/var/www/html"
        old_temp = "TEMP_DIR=$(mktemp -d /tmp/instala-wp.XXXXXX)"
        self.assertIn(old_docroot, text)
        self.assertIn(old_temp, text)
        text = text.replace(old_docroot, 'DOCROOT="$HARNESS_ROOT/docroot"')
        text = text.replace(old_temp, 'TEMP_DIR=$(mktemp -d "$TEMP_PARENT/instala-wp.XXXXXX")')
        if pause:
            trap = "trap 'exit 143' TERM"
            self.assertIn(trap, text)
            text = text.replace(
                trap,
                trap + '\n: "${READY_FILE:?}"; printf \'%s\\n\' "$$" > "$PID_FILE"; chmod 0644 "$PID_FILE"; : > "$READY_FILE"; sleep 30',
                1,
            )
        script = directory / "instala-wp-isolado.sh"
        script.write_text(text)
        script.chmod(0o755)
        return script

    def isolated_env(self, root, commands, temp_parent, ready_file=None, pid_file=None):
        env = {
            "HARNESS_ROOT": str(root),
            "TEMP_PARENT": str(temp_parent),
            "PATH": str(commands) + os.pathsep + "/usr/bin:/bin",
        }
        if ready_file is not None:
            env["READY_FILE"] = str(ready_file)
        if pid_file is not None:
            env["PID_FILE"] = str(pid_file)
        return env

    def test_temp_dir_is_removed_after_isolated_failure(self):
        with tempfile.TemporaryDirectory(prefix="wp-cleanup-falha-") as tmp:
            root = Path(tmp)
            commands = root / "commands"
            commands.mkdir()
            self.make_fake_commands(commands)
            temp_parent = root / "temp-parent"
            temp_parent.mkdir(mode=0o700)
            # mkdir -p sobre um arquivo falha logo depois de TEMP_DIR existir.
            (root / "docroot").write_text("não é um diretório")
            script = self.make_isolated_wp_script(root)
            marker = "CLEANUP_fake_marker_3"
            result = sudo_run(
                ["bash", str(script), "--password-stdin", "10.10.10.12", "http://127.0.0.1:8081"],
                input=marker + "\n",
                env=self.isolated_env(root, commands, temp_parent),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(temp_parent.iterdir()), [])
            self.assertNotIn(marker, result.stdout + result.stderr)

    def test_temp_dir_is_removed_after_term_in_isolated_harness(self):
        with tempfile.TemporaryDirectory(prefix="wp-cleanup-term-") as tmp:
            root = Path(tmp)
            commands = root / "commands"
            commands.mkdir()
            self.make_fake_commands(commands)
            temp_parent = root / "temp-parent"
            temp_parent.mkdir(mode=0o700)
            ready = root / "ready"
            pid_file = root / "pid"
            script = self.make_isolated_wp_script(root, pause=True)
            marker = "TERM_fake_marker_2"
            command = sudo_command(
                ["bash", str(script), "--password-stdin", "10.10.10.12", "http://127.0.0.1:8081"],
                env=self.isolated_env(root, commands, temp_parent, ready, pid_file),
            )
            process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
            script_pgid = None
            try:
                process.stdin.write(marker + "\n")
                process.stdin.close()
                process.stdin = None
                deadline = time.monotonic() + 10
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.05)
                if not ready.exists():
                    if process.poll() is None:
                        process.terminate()

                    stdout, stderr = process.communicate(timeout=5)

                    self.fail(
                        f"harness não alcançou o ponto de TERM; "
                        f"returncode={process.returncode}; "
                        f"stdout={stdout!r}; stderr={stderr!r}"
                    )

                script_pid = int(pid_file.read_text().strip())
                script_pgid = os.getpgid(script_pid)
                # O processo root não pode ser sinalizado diretamente por ubuntu;
                # o kill autorizado fica restrito ao grupo deste fixture.
                term = sudo_run(["kill", "-TERM", "--", f"-{script_pgid}"])
                self.assertEqual(term.returncode, 0, term.stdout + term.stderr)
                returncode = process.wait(timeout=10)
                stdout = process.stdout.read()
                stderr = process.stderr.read()
                process.stdout.close()
                process.stderr.close()
                self.assertNotEqual(returncode, 0)
                self.assertEqual(list(temp_parent.iterdir()), [])
                self.assertNotIn(marker, stdout + stderr)
            except subprocess.TimeoutExpired:
                if script_pgid is not None:
                    sudo_run(["kill", "-KILL", "--", f"-{script_pgid}"])
                process.kill()
                process.wait(timeout=5)
                self.fail("harness não terminou após TERM")
            finally:
                if process.poll() is None and script_pgid is not None:
                    sudo_run(["kill", "-KILL", "--", f"-{script_pgid}"])
                    process.kill()
                    process.wait(timeout=5)
                # Só este diretório criado pelo teste pode conter itens root.
                sudo_run(["rm", "-rf", "--", str(temp_parent)])


if __name__ == "__main__":
    unittest.main(verbosity=2)
