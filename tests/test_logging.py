"""Regression tests for error reporting, sanitization and logger lifecycle."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("log_filter", ROOT / "scripts/log_filter.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
BASH = shutil.which("bash")
if os.name == "nt":
    BASH = r"C:\Program Files\Git\bin\bash.exe"


def bash_path(path):
    value = str(path).replace("\\", "/")
    if os.name == "nt" and len(value) > 1 and value[1] == ":":
        return "/" + value[0].lower() + value[2:]
    return value


class LoggingTests(unittest.TestCase):
    def test_sanitize(self):
        value = "\x1b[31mURL=https://user:pass@example.test/image?token=secret#private token=abc ghp_123456789abcd\r"
        clean = module.sanitize(value)
        for secret in ("user:pass", "token=secret", "private", "abc", "ghp_", "\x1b", "\r"):
            self.assertNotIn(secret, clean)
        self.assertIn("example.test/image", clean)

    def run_logged(self, body, broken_logger=False):
        with tempfile.TemporaryDirectory(prefix="gns3-logging-test-") as folder:
            root = Path(folder)
            (root / "scripts").mkdir()
            shutil.copyfile(ROOT / "scripts/log_filter.py", root / "scripts/log_filter.py")
            if broken_logger:
                (root / "scripts/log_filter.py").write_text("raise SystemExit(74)\n", encoding="utf-8")
            command = '\n'.join([
                "set -Eeuo pipefail",
                'source "$1/scripts/lib/logging.sh"',
                'log_init "$2"',
                'log_stage test "Проверка ошибки"',
                body,
            ])
            env = os.environ.copy()
            # Windows Store's python3 alias must not shadow real Python in Git Bash.
            env["PATH"] = str(Path(os.sys.executable).parent) + os.pathsep + env.get("PATH", "")
            result = subprocess.run([BASH, "-c", command, "_", bash_path(ROOT), bash_path(root)],
                                    capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=30)
            logs = list(root.glob("logs/run-*"))
            self.assertEqual(len(logs), 1, result.stdout + result.stderr)
            return result, (logs[0] / "install.log").read_text(encoding="utf-8"), (logs[0] / "summary.txt").read_text(encoding="utf-8")

    def test_failure_preserves_code_and_flushes(self):
        result, log, summary = self.run_logged("bash -c 'echo last-message; exit 42'")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("last-message", log)
        self.assertIn("код: 42", log)
        self.assertIn("exit_code=42", summary)
        self.assertIn("status=failed", summary)

    def test_success_and_masking(self):
        result, log, summary = self.run_logged("printf 'token=secret https://example.test/a?key=private\\n'")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("secret", log)
        self.assertNotIn("private", log)
        self.assertIn("status=completed", summary)

    def test_pipeline_failure(self):
        result, log, summary = self.run_logged("bash -c 'exit 23' | sed 's/x/y/'")
        self.assertEqual(result.returncode, 23)
        self.assertIn("exit_code=23", summary)

    @unittest.skipIf(os.name == "nt", "POSIX signals are verified by Linux CI")
    def test_interruption(self):
        result, log, summary = self.run_logged('kill -TERM "$$"')
        self.assertEqual(result.returncode, 143)
        self.assertIn("status=interrupted", summary)

    def test_logger_failure_is_not_success(self):
        result, log, summary = self.run_logged("sleep 0.2", broken_logger=True)
        self.assertEqual(result.returncode, 74)
        self.assertIn("status=failed", summary)

    @unittest.skipIf(os.name == "nt", "POSIX process substitution signals are verified by Linux CI")
    def test_dead_logger_during_exit_still_writes_report(self):
        result, log, summary = self.run_logged('kill "$GNS3_LOG_PID"; wait "$GNS3_LOG_PID" || true')
        self.assertEqual(result.returncode, 74)
        self.assertIn("status=failed", summary)


if __name__ == "__main__":
    unittest.main()
