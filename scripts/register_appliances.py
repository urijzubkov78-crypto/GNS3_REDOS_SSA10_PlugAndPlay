#!/usr/bin/env python3
"""Register the generated SSA10 appliances through the local GNS3 2.2 API."""
import argparse
import base64
import configparser
from contextlib import contextmanager
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
import urllib.error
import urllib.request
import uuid

from log_filter import sanitize


FILES = {
    "full": ("ssa10-c2691-router.gns3a", "ssa10-c2691-isp.gns3a", "ssa10-iosvl2.gns3a"),
    "dynamips": ("ssa10-c2691-router.gns3a", "ssa10-c2691-isp.gns3a", "ssa10-etherswitch.gns3a"),
}


class RegistrationError(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        raise RegistrationError("Локальный API перенаправляет запрос; регистрация остановлена.")


class Api:
    def __init__(self, config):
        server = config["Server"]
        self.host = server.get("host", "127.0.0.1")
        if self.host not in ("127.0.0.1", "localhost", "::1"):
            raise RegistrationError("Автоимпорт рассчитан на локальный сервер GNS3 на loopback-адресе.")
        self.port = server.getint("port", 3080)
        if not 1 <= self.port <= 65535:
            raise RegistrationError("Некорректный порт локального сервера GNS3.")
        scheme = "https" if server.getboolean("ssl", False) else "http"
        host = "[::1]" if self.host == "::1" else self.host
        self.url = f"{scheme}://{host}:{self.port}/v2"
        self.headers = {}
        if server.getboolean("auth", False):
            credentials = server.get("user", "") + ":" + server.get("password", "")
            self.headers["Authorization"] = "Basic " + base64.b64encode(credentials.encode()).decode("ascii")
        # A local controller must never be contacted through an environment proxy.
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, method, path, data=None):
        body = None if data is None else json.dumps(data).encode("utf-8")
        headers = dict(self.headers)
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.url + path, data=body, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=3) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            # Never print response bodies: they can include credentials or settings.
            raise RegistrationError(f"GNS3 API: HTTP {error.code} при {method} {path}.") from None
        except (json.JSONDecodeError, UnicodeError):
            raise RegistrationError("Локальный порт отвечает некорректным JSON; проверьте сервер GNS3.") from None


def validate_version(api):
    version = api.request("GET", "/version")
    expected = api.expected_version
    if not isinstance(version, dict) or version.get("version") != expected:
        raise RegistrationError(f"Для автоматической регистрации требуется GNS3 Server {expected}.")


@contextmanager
def local_server(api, config_path):
    """Reuse a live controller; otherwise start and stop only our own process."""
    try:
        validate_version(api)
    except urllib.error.URLError as error:
        if not isinstance(error.reason, ConnectionRefusedError):
            raise RegistrationError("Не удалось подключиться к локальному GNS3 API.") from None
    else:
        print("[OK] Используется уже работающий локальный сервер GNS3.")
        yield
        return

    executable = shutil.which("gns3server")
    if executable is None:
        candidate = Path.home() / ".local/bin/gns3server"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            executable = str(candidate)
    if executable is None:
        raise RegistrationError("gns3server не найден. Сначала установите программные компоненты.")
    # Refuse to start a second controller when the target port is in use.
    family = socket.AF_INET6 if api.host == "::1" else socket.AF_INET
    with socket.socket(family) as probe:
        try:
            probe.bind((api.host, api.port))
        except OSError:
            raise RegistrationError("Порт GNS3 занят, но API недоступно; второй сервер не запущен.") from None

    process = None
    with tempfile.TemporaryFile() as output:
        try:
            print("[INFO] Временно запускается локальный GNS3 Server для сохранения шаблонов.")
            process = subprocess.Popen(
                [executable, "--config", str(config_path), "--host", api.host, "--port", str(api.port), "--local", "--quiet"],
                stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                cwd=str(config_path.parent),
            )
            deadline = time.monotonic() + 30
            while True:
                if process.poll() is not None:
                    raise RegistrationError("Локальный GNS3 Server завершился до готовности API. Проверьте журнал GNS3.")
                try:
                    validate_version(api)
                    break
                except urllib.error.URLError:
                    if time.monotonic() >= deadline:
                        raise RegistrationError("GNS3 API не стало доступно за 30 секунд.") from None
                    time.sleep(0.25)
            yield
        except (RegistrationError, KeyboardInterrupt, SystemExit):
            output.seek(0, os.SEEK_END)
            output.seek(max(0, output.tell() - 8192))
            tail = output.read().decode("utf-8", errors="replace").splitlines()[-15:]
            for line in tail:
                print("[GNS3] " + sanitize(line), file=sys.stderr)
            raise
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


def qemu_executable():
    for name in ("qemu-system-x86_64", "qemu-kvm"):
        path = shutil.which(name)
        if path:
            return path
    if os.access("/usr/libexec/qemu-kvm", os.X_OK):
        return "/usr/libexec/qemu-kvm"
    raise RegistrationError("Не найден QEMU для IOSvL2. Сначала установите профиль Full.")


def build_template(appliance, images_root, qemu_path=None):
    kind = "dynamips" if "dynamips" in appliance else "qemu"
    identifier = str(uuid.UUID(appliance["appliance_id"]))
    versions = appliance["versions"]
    if len(versions) != 1:
        raise RegistrationError("Ожидается ровно одна версия в комплектном шаблоне.")
    switch = appliance["category"] == "multilayer_switch"
    data = {
        "template_id": identifier,
        "name": appliance["name"],
        "template_type": kind,
        "compute_id": "local",
        "category": "switch" if switch else "router",
        "default_name_format": "SW{0}" if switch else ("ISP{0}" if " ISP" in appliance["name"] else "R{0}"),
        "symbol": ":/symbols/ethernet_switch.svg" if switch else ":/symbols/router.svg",
    }
    settings = dict(appliance[kind])
    key = "image" if kind == "dynamips" else "hda_disk_image"
    filename = versions[0]["images"][key]
    if Path(filename).name != filename or filename in ("", ".", ".."):
        raise RegistrationError("Некорректное имя файла образа в комплектном шаблоне.")
    data[key] = str(images_root / ("IOS" if kind == "dynamips" else "QEMU") / filename)
    if kind == "qemu":
        # Appliance-only keys are not properties of a server template.
        architecture = settings.pop("arch", "x86_64")
        settings.pop("kvm", None)
        settings["platform"] = architecture
        settings["qemu_path"] = qemu_path if qemu_path is not None else qemu_executable()
        settings["port_name_format"] = appliance.get("port_name_format", "Gi{1}/{0}")
        settings["port_segment_size"] = appliance.get("port_segment_size", 4)
    data.update(settings)
    return data


def register_templates(api, desired, check_only=False):
    existing = api.request("GET", "/templates")
    if not isinstance(existing, list):
        raise RegistrationError("GNS3 API вернуло некорректный список шаблонов.")
    expected = []
    for template in desired:
        matches = [item for item in existing if item.get("template_id") == template["template_id"]]
        if not matches:
            matches = [item for item in existing if item.get("name") == template["name"]]
        if len(matches) > 1:
            raise RegistrationError(f"Несколько шаблонов с именем {template['name']}; устраните дубли в GNS3.")
        key = "image" if template["template_type"] == "dynamips" else "hda_disk_image"
        if matches:
            match = matches[0]
            if match.get("template_type") != template["template_type"] or match.get("compute_id") != "local" or match.get("builtin"):
                raise RegistrationError(f"Существующий {template['name']} относится к другому типу или серверу.")
            identifier = match["template_id"]
            if match.get(key) != template[key]:
                if check_only:
                    raise RegistrationError(f"В {template['name']} указан другой файл образа.")
                api.request("PUT", f"/templates/{identifier}", {key: template[key]})
            print(f"[OK] Шаблон уже зарегистрирован: {template['name']}")
        elif check_only:
            raise RegistrationError(f"Не зарегистрирован шаблон {template['name']}.")
        else:
            result = api.request("POST", "/templates", template)
            identifier = result.get("template_id")
            if identifier != template["template_id"]:
                raise RegistrationError("GNS3 вернуло неожиданный идентификатор созданного шаблона.")
            print(f"[OK] Зарегистрирован: {template['name']}")
        expected.append((identifier, template, key))
    # A successful POST alone is insufficient: read back all three templates.
    for identifier, template, key in expected:
        saved = api.request("GET", f"/templates/{identifier}")
        if saved.get(key) != template[key] or saved.get("compute_id") != "local" or saved.get("name") != template["name"]:
            raise RegistrationError(f"Проверка зарегистрированного {template['name']} не пройдена.")
    print(f"[OK] В GNS3 доступны {len(expected)} шаблона SSA10. Ручной импорт не требуется.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=FILES, default="full")
    parser.add_argument("--appliances-dir", type=Path, default=Path.home() / "GNS3/appliances")
    parser.add_argument("--config", type=Path, default=Path.home() / ".config/GNS3/2.2/gns3_server.conf")
    parser.add_argument("--check", action="store_true", help="Проверить регистрацию без изменения шаблонов")
    parser.add_argument("--expected-version", default="2.2.61")
    args = parser.parse_args(argv)
    try:
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            raise RegistrationError("Запускайте от обычного пользователя GNS3, без sudo.")
        config_path = args.config.expanduser().resolve()
        config = configparser.ConfigParser(interpolation=None)
        if not config.read(config_path, encoding="utf-8") or not config.has_section("Server"):
            raise RegistrationError("Не найден конфиг GNS3 Server. Сначала установите программные компоненты.")
        images_root = Path(config["Server"].get("images_path", str(Path.home() / "GNS3/images"))).expanduser().resolve()
        desired = []
        for filename in FILES[args.profile]:
            if not (args.appliances_dir / filename).is_file():
                raise RegistrationError(f"Не найден {filename}. Сначала создайте шаблоны из установленных образов.")
            with (args.appliances_dir / filename).open(encoding="utf-8") as source:
                desired.append(build_template(json.load(source), images_root))
        api = Api(config)
        api.expected_version = args.expected_version
        previous_term = signal.signal(signal.SIGTERM, lambda number, frame: sys.exit(143))
        try:
            with local_server(api, config_path):
                register_templates(api, desired, args.check)
        finally:
            signal.signal(signal.SIGTERM, previous_term)
        print("[INFO] Откройте GNS3 → Browse all devices. Если программа уже открыта, перезапустите её.")
        return 0
    except KeyboardInterrupt:
        print("[ERROR] Регистрация прервана пользователем.", file=sys.stderr)
        return 130
    except (RegistrationError, OSError, ValueError, KeyError, TypeError, configparser.Error):
        # Keep arbitrary config contents, HTTP headers and OS errors out of logs.
        error = sys.exc_info()[1]
        message = str(error) if isinstance(error, RegistrationError) else "Проверьте файлы шаблонов, конфиг и доступность GNS3 Server."
        print(f"[ERROR] {message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
