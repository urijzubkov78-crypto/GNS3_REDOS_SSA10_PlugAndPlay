"""Exercise confirmation prompts through a real Linux pseudo-terminal."""
import errno
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

if sys.platform.startswith("linux"):
    import pty


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform.startswith("linux"), "PTY regression requires Linux")
class TerminalTests(unittest.TestCase):
    def test_confirmation_is_visible_before_reply_and_cancel_stops_install(self):
        """A line-buffered log filter must not hide the unterminated prompt."""
        bash = shutil.which("bash")
        self.assertIsNotNone(bash, "bash is required for the installer")
        with tempfile.TemporaryDirectory(prefix="gns3-terminal-test-") as folder:
            root = Path(folder)
            for relative in (
                "setup.sh",
                "scripts/lib/common.sh",
                "scripts/lib/logging.sh",
                "scripts/log_filter.py",
                "config/lab.conf",
            ):
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / relative, destination)

            # No RPM, sudo, network, image installation, or real preflight runs.
            (root / "scripts/preflight_redos8.sh").write_text(
                "#!/usr/bin/env bash\nexit 0\n", encoding="utf-8"
            )
            (root / "scripts/install_gns3_redos8.sh").write_text(
                "#!/usr/bin/env bash\nprintf 'INSTALLER_WAS_RUN\\n'\nexit 99\n",
                encoding="utf-8",
            )

            master, slave = pty.openpty()
            process = None
            output = bytearray()
            try:
                process = subprocess.Popen(
                    [bash, str(root / "setup.sh"), "--install"],
                    cwd=root,
                    stdin=slave,
                    stdout=slave,
                    stderr=slave,
                    close_fds=True,
                )
                os.close(slave)
                slave = None
                with selectors.DefaultSelector() as selector:
                    selector.register(master, selectors.EVENT_READ)
                    deadline = time.monotonic() + 15
                    while b"[y/N]: " not in output:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            self.fail(
                                "Confirmation prompt was not visible before a reply:\n"
                                + output.decode("utf-8", errors="replace")
                            )
                        if not selector.select(min(remaining, 0.2)):
                            if process.poll() is not None:
                                self.fail(
                                    "Installer exited before confirmation:\n"
                                    + output.decode("utf-8", errors="replace")
                                )
                            continue
                        try:
                            chunk = os.read(master, 65536)
                        except OSError as error:
                            if error.errno != errno.EIO:
                                raise
                            chunk = b""
                        if not chunk:
                            self.fail(
                                "Terminal closed before confirmation:\n"
                                + output.decode("utf-8", errors="replace")
                            )
                        output.extend(chunk)

                    # Nothing has been sent before the entire prompt is visible.
                    self.assertIsNone(process.poll())
                    os.write(master, b"n\n")
                    process.wait(timeout=15)
                    while selector.select(0):
                        try:
                            chunk = os.read(master, 65536)
                        except OSError as error:
                            if error.errno != errno.EIO:
                                raise
                            break
                        if not chunk:
                            break
                        output.extend(chunk)

                transcript = output.decode("utf-8", errors="replace")
                self.assertNotEqual(process.returncode, 0, transcript)
                self.assertNotIn("INSTALLER_WAS_RUN", transcript)
                reports = list(root.glob("logs/run-*/summary.txt"))
                self.assertEqual(len(reports), 1, transcript)
                report = reports[0].read_text(encoding="utf-8")
                self.assertIn("status=cancelled", report, transcript)
                self.assertNotIn("exit_code=0\n", report, transcript)
                log = reports[0].with_name("install.log").read_text(encoding="utf-8")
                self.assertIn("Установка отменена", log)
                self.assertNotIn("INSTALLER_WAS_RUN", log)
            finally:
                if process is not None and process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                if slave is not None:
                    os.close(slave)
                os.close(master)


if __name__ == "__main__":
    unittest.main()
