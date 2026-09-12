import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("pin_camera_routes", ROOT / "scripts" / "pin_camera_routes.py")
MOD = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MOD)

BOOTSTRAP = """[Interface]\nPrivateKey = test\nAddress = 10.9.0.2/32\n\n[Peer]\nPublicKey = peer\nAllowedIPs = 192.168.0.0/24\nEndpoint = example.invalid:51820\n"""


class CameraRouteTests(unittest.TestCase):
    def test_renders_camera_only_32_routes(self):
        networks = MOD.bootstrap_networks(BOOTSTRAP)
        with tempfile.TemporaryDirectory() as tmp:
            inv = pathlib.Path(tmp) / "cameras.json"
            inv.write_text(json.dumps({"cameras": [
                {"ip": "192.168.0.201"}, {"ip": "192.168.0.202"}, {"ip": "192.168.0.203"}
            ]}), encoding="utf-8")
            ips = MOD.inventory_ips(inv, 3, networks)
        rendered = MOD.render_runtime(BOOTSTRAP, ips)
        self.assertIn("AllowedIPs = 192.168.0.201/32, 192.168.0.202/32, 192.168.0.203/32", rendered)
        self.assertNotIn("192.168.0.0/24", rendered)

    def test_inventory_cannot_escape_bootstrap_network(self):
        networks = MOD.bootstrap_networks(BOOTSTRAP)
        with tempfile.TemporaryDirectory() as tmp:
            inv = pathlib.Path(tmp) / "cameras.json"
            inv.write_text(json.dumps({"cameras": [
                {"ip": "192.168.0.201"}, {"ip": "192.168.0.202"}, {"ip": "10.0.0.1"}
            ]}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "outside the TP-Link bootstrap routes"):
                MOD.inventory_ips(inv, 3, networks)

    def test_requires_exact_expected_camera_count_once_nonempty(self):
        networks = MOD.bootstrap_networks(BOOTSTRAP)
        with tempfile.TemporaryDirectory() as tmp:
            inv = pathlib.Path(tmp) / "cameras.json"
            inv.write_text(json.dumps({"cameras": [{"ip": "192.168.0.201"}]}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "expected exactly 3"):
                MOD.inventory_ips(inv, 3, networks)


if __name__ == "__main__":
    unittest.main()
