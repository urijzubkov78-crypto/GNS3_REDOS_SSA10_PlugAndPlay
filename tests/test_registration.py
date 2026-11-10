"""Regression coverage for idempotent local template registration."""
import copy
import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
try:
    spec = importlib.util.spec_from_file_location("register_appliances", SCRIPTS / "register_appliances.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
finally:
    sys.path.pop(0)


def appliance(kind="dynamips"):
    return {
        "appliance_id": "4d976437-ed2d-4ef2-a064-95d625fc56e1",
        "name": "SSA10 Cisco 2691 Router" if kind == "dynamips" else "SSA10 Cisco IOSvL2",
        "category": "router" if kind == "dynamips" else "multilayer_switch",
        kind: {"platform": "c2691", "ram": 192} if kind == "dynamips" else {
            "arch": "x86_64", "kvm": "require", "ram": 768, "adapters": 16, "adapter_type": "e1000",
        },
        "versions": [{"images": {"image" if kind == "dynamips" else "hda_disk_image": "router.bin" if kind == "dynamips" else "switch.qcow2"}}],
    }


class MemoryApi:
    def __init__(self, initial=()):
        self.templates = {item["template_id"]: copy.deepcopy(item) for item in initial}
        self.writes = []

    def request(self, method, path, data=None):
        if method == "GET":
            return copy.deepcopy(list(self.templates.values()) if path == "/templates" else self.templates[path.rsplit("/", 1)[1]])
        self.writes.append((method, path, copy.deepcopy(data)))
        if method == "POST":
            if data["template_id"] in self.templates:
                raise AssertionError("Duplicate creation")
            self.templates[data["template_id"]] = copy.deepcopy(data)
            return copy.deepcopy(data)
        if method == "PUT":
            identifier = path.rsplit("/", 1)[1]
            self.templates[identifier].update(copy.deepcopy(data))
            return copy.deepcopy(self.templates[identifier])
        raise AssertionError(method)


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.template = module.build_template(appliance(), Path("/installed/images"))

    def test_repeat_does_not_duplicate_or_reset_idlepc(self):
        api = MemoryApi()
        module.register_templates(api, [self.template])
        api.templates[self.template["template_id"]]["idlepc"] = "0x12345678"
        module.register_templates(api, [self.template])
        self.assertEqual(len(api.templates), 1)
        self.assertEqual(len(api.writes), 1)
        self.assertEqual(api.templates[self.template["template_id"]]["idlepc"], "0x12345678")

    def test_reuses_manually_imported_template_and_repairs_image_only(self):
        manual = dict(self.template, template_id="6977f299-ff41-4507-a1dd-1afbfe208cf9", image="old.bin", ram=384)
        api = MemoryApi([manual])
        module.register_templates(api, [self.template])
        self.assertEqual(len(api.templates), 1)
        self.assertEqual(api.templates[manual["template_id"]]["ram"], 384)
        self.assertEqual(api.templates[manual["template_id"]]["image"], self.template["image"])
        self.assertEqual(api.writes[0][2], {"image": self.template["image"]})

    def test_does_not_modify_a_remote_template(self):
        api = MemoryApi([dict(self.template, compute_id="remote-compute")])
        with self.assertRaises(module.RegistrationError):
            module.register_templates(api, [self.template])
        self.assertEqual(api.writes, [])

    def test_check_missing_template_never_creates_it(self):
        api = MemoryApi()
        with self.assertRaises(module.RegistrationError):
            module.register_templates(api, [self.template], check_only=True)
        self.assertEqual(api.writes, [])

    def test_ambiguous_manual_names_are_rejected(self):
        api = MemoryApi([
            dict(self.template, template_id="first"),
            dict(self.template, template_id="second"),
        ])
        with self.assertRaises(module.RegistrationError):
            module.register_templates(api, [self.template])
        self.assertEqual(api.writes, [])

    def test_qemu_fields_match_server_template_and_switch_category(self):
        data = module.build_template(appliance("qemu"), Path("/installed/images"), qemu_path="/usr/libexec/qemu-kvm")
        self.assertEqual(data["category"], "switch")
        self.assertEqual(data["compute_id"], "local")
        self.assertEqual(data["platform"], "x86_64")
        self.assertEqual(data["qemu_path"], "/usr/libexec/qemu-kvm")
        self.assertEqual(data["hda_disk_image"], str(Path("/installed/images/QEMU/switch.qcow2")))
        self.assertNotIn("kvm", data)
        self.assertNotIn("arch", data)


if __name__ == "__main__":
    unittest.main()
