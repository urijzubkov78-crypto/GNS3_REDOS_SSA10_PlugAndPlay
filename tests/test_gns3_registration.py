"""Exercise registration and persistence against a real GNS3 2.2 controller."""
import configparser
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
SERVER = shutil.which("gns3server")
BASH = shutil.which("bash")
AVAILABLE = os.name == "posix" and SERVER and BASH and os.geteuid() != 0
REQUIRED = os.environ.get("GNS3_INTEGRATION_REQUIRED") == "1"


@unittest.skipUnless(AVAILABLE or REQUIRED, "Real controller integration requires Linux, gns3server and a non-root user")
class GNS3RegistrationIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(AVAILABLE, "GNS3 integration is required, but its dependencies or non-root user are unavailable")
        self.directory = tempfile.TemporaryDirectory(prefix="gns3-real-registration-")
        self.addCleanup(self.directory.cleanup)
        self.folder = Path(self.directory.name)
        self.env = os.environ.copy()
        self.env["HOME"] = str(self.folder / "home")
        Path(self.env["HOME"]).mkdir()
        self.images = self.folder / "images"
        (self.images / "IOS").mkdir(parents=True)
        (self.images / "QEMU").mkdir()
        self.appliances = self.folder / "appliances"
        self.router = "c2691-entservicesk9-mz.124-13b.bin"
        self.switch = "vios_l2-adventerprisek9-m.ssa.high_iron_20200929.qcow2"
        (self.images / "IOS" / self.router).write_bytes(b"router fixture for template registration")
        (self.images / "QEMU" / self.switch).write_bytes(b"switch fixture for template registration")
        # Registration needs an executable path, but never starts a QEMU VM.
        binaries = self.folder / "bin"
        binaries.mkdir()
        qemu = binaries / "qemu-system-x86_64"
        qemu.write_text("#!/bin/sh\nprintf 'QEMU emulator version 8.2.0\\n'\n", encoding="utf-8")
        qemu.chmod(0o755)
        self.env["PATH"] = str(binaries) + os.pathsep + self.env.get("PATH", "")
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            self.port = probe.getsockname()[1]
        self.url = f"http://127.0.0.1:{self.port}/v2"
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.config_path = self.folder / "gns3_server.conf"
        config = configparser.ConfigParser()
        config["Server"] = {
            "host": "127.0.0.1", "port": str(self.port), "local": "True", "auth": "False",
            "images_path": str(self.images), "projects_path": str(self.folder / "projects"),
            "configs_path": str(self.folder / "configs"), "appliances_path": str(self.appliances),
            "install_builtin_appliances": "False",
        }
        config["Qemu"] = {"enable_hardware_acceleration": "True", "require_hardware_acceleration": "True"}
        with self.config_path.open("w", encoding="utf-8") as stream:
            config.write(stream)
        self.config_path.chmod(0o600)
        generated = subprocess.run(
            [BASH, str(ROOT / "scripts/generate_appliances.sh"), "--profile", "full",
             "--images-root", str(self.images), "--output-dir", str(self.appliances), "--no-user-copy"],
            env=self.env, cwd=self.folder, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(generated.returncode, 0, generated.stdout + generated.stderr)
        # A stale appliance from another profile must not be imported via a glob.
        (self.appliances / "ssa10-etherswitch.gns3a").write_text("stale other-profile fixture", encoding="utf-8")

    def api(self, path, data=None, method="GET"):
        body = None if data is None else json.dumps(data).encode("utf-8")
        request = urllib.request.Request(self.url + path, data=body, method=method,
                                         headers={"Content-Type": "application/json"})
        with self.opener.open(request, timeout=1) as response:
            return json.load(response)

    def api_is_running(self):
        try:
            return self.api("/version").get("version", "").startswith("2.2.")
        except (OSError, urllib.error.URLError):
            return False

    def run_registrar(self, *extra):
        process = subprocess.Popen(
            [sys.executable, str(ROOT / "scripts/register_appliances.py"), "--profile", "full",
             "--appliances-dir", str(self.appliances), "--config", str(self.config_path), *extra],
            env=self.env, cwd=self.folder, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, start_new_session=True,
        )
        # A buggy registrar must not leak its own controller into later tests.
        def cleanup_group():
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        self.addCleanup(cleanup_group)
        try:
            stdout, stderr = process.communicate(timeout=50)
        except subprocess.TimeoutExpired:
            cleanup_group()
            process.communicate(timeout=5)
            self.fail("Registrar did not finish within 50 seconds")
        self.assertEqual(process.returncode, 0, stdout + stderr)
        return stdout

    def start_server(self):
        logfile = (self.folder / f"external-server-{time.monotonic_ns()}.log").open("w+", encoding="utf-8")
        self.addCleanup(logfile.close)
        process = subprocess.Popen(
            [SERVER, "--config", str(self.config_path), "--host", "127.0.0.1", "--port", str(self.port), "--local"],
            env=self.env, cwd=self.folder, stdin=subprocess.DEVNULL, stdout=logfile, stderr=subprocess.STDOUT,
        )
        self.addCleanup(self.stop_server, process)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if process.poll() is not None:
                logfile.seek(0)
                self.fail("Real GNS3 server exited before readiness:\n" + logfile.read())
            if self.api_is_running():
                return process
            time.sleep(0.1)
        logfile.seek(0)
        self.fail("Real GNS3 API did not become ready:\n" + logfile.read())

    @staticmethod
    def stop_server(process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    def ssa_templates(self):
        return {item["name"]: item for item in self.api("/templates") if item["name"].startswith("SSA10 ")}

    def test_registration_persists_and_reuses_existing_controller_without_duplicates(self):
        self.assertFalse(self.api_is_running())
        self.run_registrar()
        self.assertFalse(self.api_is_running(), "Registrar left its temporary server running")

        server = self.start_server()
        templates = self.ssa_templates()
        self.assertEqual(set(templates), {"SSA10 Cisco 2691 Router", "SSA10 Cisco 2691 ISP", "SSA10 Cisco IOSvL2"})
        self.assertEqual(len([item for item in self.api("/templates") if item["name"].startswith("SSA10 ")]), 3)
        router = templates["SSA10 Cisco 2691 Router"]
        isp = templates["SSA10 Cisco 2691 ISP"]
        switch = templates["SSA10 Cisco IOSvL2"]
        self.assertEqual(router["template_type"], "dynamips")
        self.assertEqual(router["category"], "router")
        self.assertEqual(router["image"], str(self.images / "IOS" / self.router))
        self.assertEqual(isp["slot1"], "NM-1FE-TX")
        self.assertEqual(switch["template_type"], "qemu")
        self.assertEqual(switch["category"], "switch")
        self.assertEqual(switch["hda_disk_image"], str(self.images / "QEMU" / self.switch))
        self.assertEqual(switch["adapters"], 16)
        self.assertEqual(switch["port_name_format"], "Gi{1}/{0}")
        for template in templates.values():
            self.assertEqual(template["compute_id"], "local")
        self.api(f"/templates/{router['template_id']}", {"idlepc": "0x12345678"}, method="PUT")

        self.run_registrar()
        self.assertIsNone(server.poll(), "Registrar terminated a controller it did not start")
        repeated = self.ssa_templates()
        self.assertEqual({name: item["template_id"] for name, item in repeated.items()},
                         {name: item["template_id"] for name, item in templates.items()})
        self.assertEqual(repeated[router["name"]]["idlepc"], "0x12345678")
        self.assertEqual(len([item for item in self.api("/templates") if item["name"].startswith("SSA10 ")]), 3)
        self.run_registrar("--check")
        self.assertIsNone(server.poll())

        self.stop_server(server)
        self.run_registrar("--check")
        self.assertFalse(self.api_is_running(), "Read-only check leaked a temporary controller")
        restarted = self.start_server()
        persisted = self.ssa_templates()
        self.assertEqual(set(persisted), set(templates))
        self.assertEqual(persisted[router["name"]]["idlepc"], "0x12345678")
        self.assertIsNone(restarted.poll())


if __name__ == "__main__":
    unittest.main()
